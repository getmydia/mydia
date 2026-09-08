defmodule Mydia.Downloads.FfmpegMp4HwaccelTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.FfmpegMp4Transcoder
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc]
  }

  defp args(opts) do
    FfmpegMp4Transcoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out.mp4", :p1080, opts)
  end

  test "without capabilities the arguments are unchanged" do
    result = args([])

    assert "libx264" in result
    refute "-hwaccel" in result
  end

  test "a decodable source uses the hardware encoder" do
    result = args(capabilities: @vaapi, source_codec: "hevc")

    assert "h264_vaapi" in result
    assert Enum.find_index(result, &(&1 == "-hwaccel")) < Enum.find_index(result, &(&1 == "-i"))
  end

  test "the fragmented MP4 flags survive acceleration" do
    # These are what make the file playable before the download completes;
    # losing them would break progressive playback silently.
    result = args(capabilities: @vaapi, source_codec: "hevc")

    assert "+frag_keyframe+empty_moov+default_base_moof" in result
  end

  test "the resolution preset is applied through the filter, not -s" do
    # -s and a hardware filter chain cannot both set geometry; -s would force a
    # software scale after the frames are already on the GPU.
    result = args(capabilities: @vaapi, source_codec: "hevc")

    refute "-s" in result
    assert Enum.any?(result, &String.contains?(&1, "scale_vaapi"))
  end

  test "retries a hardware failure once and no more" do
    output = "Device creation failed: -5."

    assert FfmpegMp4Transcoder.retry_in_software?(%{
             hwaccel_retried: false,
             output_buffer: output
           })

    refute FfmpegMp4Transcoder.retry_in_software?(%{hwaccel_retried: true, output_buffer: output})
  end

  test "an ordinary encode failure is never retried" do
    refute FfmpegMp4Transcoder.retry_in_software?(%{
             hwaccel_retried: false,
             output_buffer: "Invalid data found when processing input"
           })
  end

  describe "the non-zero exit handler" do
    # handle_info/2 is a GenServer callback, so it is already a public
    # function -- called directly here the same way retry_in_software?/1's
    # tests above call a decision function directly, without a live
    # GenServer. input_path points nowhere on purpose: it makes whatever
    # ffmpeg process handle_info/2 spawns for the software retry fail almost
    # instantly (the codebase already assumes ffmpeg is on PATH for the
    # default `mix test` run -- see test/mydia/library/ffmpeg_test.exs).
    # These tests only care what handle_info/2 itself does synchronously,
    # never what that spawned process eventually reports.
    defp state(output_path, on_error, output_buffer) do
      opts = [
        input_path: "/nonexistent/definitely-not-here.mkv",
        output_path: output_path,
        resolution: :p720
      ]

      %FfmpegMp4Transcoder.State{
        input_path: "/nonexistent/definitely-not-here.mkv",
        output_path: output_path,
        resolution: :p720,
        ffmpeg_pid: 999_999,
        ffmpeg_port: make_ref(),
        on_error: on_error,
        buffer: "",
        job_id: "job-1",
        source_codec: "hevc",
        opts: opts,
        hwaccel_lease: nil,
        hwaccel_retried: false,
        output_buffer: output_buffer
      }
    end

    setup do
      output_path =
        Path.join(System.tmp_dir!(), "mp4_hwaccel_test_#{System.unique_integer([:positive])}.mp4")

      on_exit(fn -> File.rm(output_path) end)

      %{output_path: output_path}
    end

    test "a retryable hardware failure does not report on_error before the software restart",
         %{output_path: output_path} do
      # Stands in for -movflags +empty_moov having already written a moov atom
      # for the failed hardware attempt (see restart_in_software/1's comment):
      # a real file sits at output_path before the retry runs.
      File.write!(output_path, "partial hardware output")

      test_pid = self()
      on_error = fn msg -> send(test_pid, {:on_error_called, msg}) end

      state = state(output_path, on_error, "Device creation failed: -5.")

      assert {:noreply, new_state} =
               FfmpegMp4Transcoder.handle_info({state.ffmpeg_port, {:exit_status, 1}}, state)

      # The bug: on_error used to fire unconditionally before this branch was
      # even chosen, marking the download job failed while this software
      # restart was still starting behind it.
      refute_received {:on_error_called, _}

      assert new_state.hwaccel_retried
      assert is_port(new_state.ffmpeg_port)

      # The partial hardware output must be gone before the software retry's
      # ffmpeg process starts, or that process would stop at ffmpeg's
      # interactive overwrite prompt (no -y in the argument list) and hang.
      refute File.exists?(output_path)
    end

    test "a non-retryable failure still reports on_error and stops the job",
         %{output_path: output_path} do
      test_pid = self()
      on_error = fn msg -> send(test_pid, {:on_error_called, msg}) end

      state = state(output_path, on_error, "Invalid data found when processing input")

      assert {:stop, {:ffmpeg_failed, 1}, ^state} =
               FfmpegMp4Transcoder.handle_info({state.ffmpeg_port, {:exit_status, 1}}, state)

      assert_received {:on_error_called, msg}
      assert msg =~ "FFmpeg exited with status 1"
    end
  end
end
