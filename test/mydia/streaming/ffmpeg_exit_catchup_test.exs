defmodule Mydia.Streaming.FfmpegExitCatchupTest do
  # Drives the REAL FfmpegHlsTranscoder GenServer through its two exit
  # handlers, rather than calling final_segment_catchup/1 directly against a
  # hand-built %State{}. The unit-level tests in ffmpeg_segment_poll_test.exs
  # prove the catch-up read's diffing logic is correct; they do not prove it
  # is actually wired into the handlers that stop the GenServer, because they
  # never send a real {port, {:exit_status, _}} message. This file exists to
  # close exactly that gap: deleting the `final_segment_catchup(state)` call
  # from either exit clause must make one of these tests fail.
  #
  # The FFmpeg process is pointed at "pipe:0" (its own stdin) with nothing
  # ever written to it, so it blocks in its input probe indefinitely and
  # never emits its own exit_status on its own. That removes the only race
  # that would otherwise matter here: without it, a real encode finishing
  # early could beat (or mask the absence of) the synthetic exit message this
  # test sends, and the test would pass or fail for the wrong reason. The
  # blocked process is killed by `terminate/2` (via stop_transcoding, or via
  # the GenServer's own termination after the synthetic exit stops it) either
  # way, so nothing is left running after the test.
  #
  # PATH-gated the same way test/mydia/streaming/ffmpeg_scale_live_test.exs
  # gates its own real-FFmpeg tests: a real ExUnit skip, reported as skipped
  # rather than passing, on a host with no FFmpeg on PATH.
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  @moduletag :requires_ffmpeg

  if is_nil(System.find_executable("ffmpeg")) do
    @moduletag skip: "ffmpeg not found on PATH"
  end

  setup do
    dir =
      Path.join(System.tmp_dir!(), "hls_exit_catchup_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  defp playlist_path(dir), do: Path.join(dir, "index.m3u8")

  defp write_playlist(dir, indices) do
    entries =
      Enum.map_join(indices, fn index ->
        name = "segment_#{String.pad_leading(to_string(index), 5, "0")}.ts"
        "#EXTINF:4.000000,\n#{name}\n"
      end)

    File.write!(playlist_path(dir), "#EXTM3U\n" <> entries)
  end

  # A transcoder whose FFmpeg process blocks reading its own stdin and so
  # never exits on its own. Callers inject the exit message themselves.
  defp start_blocked_transcoder(dir) do
    test_pid = self()

    {:ok, pid} =
      FfmpegHlsTranscoder.start_transcoding(
        input_path: "pipe:0",
        output_dir: dir,
        on_segments: fn indices -> send(test_pid, {:segments, indices}) end
      )

    on_exit(fn ->
      if Process.alive?(pid), do: FfmpegHlsTranscoder.stop_transcoding(pid)
    end)

    pid
  end

  # Waits for the poll loop's first pass (scheduled at 100ms) to report the
  # given indices, proving the loop is genuinely running rather than
  # asserting on a callback that happens to never have been called yet.
  defp await_first_poll(indices) do
    assert_receive {:segments, ^indices}, 1_000
  end

  describe "the zero-exit handler" do
    test "reports a tail segment finished after the last poll, before stopping", %{dir: dir} do
      pid = start_blocked_transcoder(dir)

      write_playlist(dir, [0])
      await_first_poll([0])

      # Written in the gap between the poll that just ran and process exit.
      # No poll is scheduled to see it before the exit message below arrives
      # (the next one is 250ms out), so only the exit handler's own
      # catch-up read can report it.
      write_playlist(dir, [0, 1])

      %{ffmpeg_port: port} = :sys.get_state(pid)
      send(pid, {port, {:exit_status, 0}})

      assert_receive {:segments, [1]}, 1_000
    end
  end

  describe "the non-zero-exit handler" do
    test "reports a tail segment finished after the last poll, before stopping", %{dir: dir} do
      pid = start_blocked_transcoder(dir)

      write_playlist(dir, [0])
      await_first_poll([0])

      write_playlist(dir, [0, 1])

      %{ffmpeg_port: port} = :sys.get_state(pid)
      send(pid, {port, {:exit_status, 1}})

      assert_receive {:segments, [1]}, 1_000
    end
  end
end
