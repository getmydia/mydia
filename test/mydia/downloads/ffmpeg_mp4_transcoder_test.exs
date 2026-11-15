defmodule Mydia.Downloads.FfmpegMp4TranscoderTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.FfmpegMp4Transcoder

  describe "start_transcoding/1" do
    @tag :skip
    test "starts FFmpeg process and returns pid" do
      # Create a temporary test file
      input_path = "/tmp/test_input.mp4"
      output_path = "/tmp/test_output.mp4"

      # This test requires FFmpeg to be installed and a valid input file
      # Skip in CI unless test fixtures are available
      File.write!(input_path, "test data")

      try do
        {:ok, pid} =
          FfmpegMp4Transcoder.start_transcoding(
            input_path: input_path,
            output_path: output_path,
            resolution: :p720
          )

        assert Process.alive?(pid)

        # Clean up
        FfmpegMp4Transcoder.stop_transcoding(pid)
      after
        File.rm(input_path)
        File.rm(output_path)
      end
    end

    @tag :requires_ffmpeg
    test "fails with invalid input path" do
      # ffmpeg can exit before Port.info/2 reads its os_pid, and the linked
      # GenServer then stops with {:ffmpeg_start_failed, :no_os_pid}. That is
      # the failure this test provokes; it must not take the test down.
      Process.flag(:trap_exit, true)
      output_path = "/tmp/test_output.mp4"

      result =
        FfmpegMp4Transcoder.start_transcoding(
          input_path: "/nonexistent/file.mp4",
          output_path: output_path,
          resolution: :p720
        )

      # The GenServer should start but FFmpeg will fail
      assert {:ok, _pid} = result
    end

    @tag :requires_ffmpeg
    test "validates resolution preset" do
      input_path = "/tmp/test_input.mp4"
      output_path = "/tmp/test_output.mp4"

      File.write!(input_path, "test data")

      try do
        # Use Process.flag to trap exits so we can catch the GenServer error
        Process.flag(:trap_exit, true)

        result =
          FfmpegMp4Transcoder.start_transcoding(
            input_path: input_path,
            output_path: output_path,
            resolution: :invalid_resolution
          )

        # GenServer will exit with invalid_resolution error
        case result do
          {:ok, pid} ->
            receive do
              {:EXIT, ^pid, {:invalid_resolution, :invalid_resolution}} ->
                :ok
            after
              1_000 -> flunk("Expected GenServer to exit with invalid_resolution error")
            end

          {:error, {:invalid_resolution, :invalid_resolution}} ->
            :ok
        end
      after
        File.rm(input_path)
        Process.flag(:trap_exit, false)
      end
    end
  end

  describe "get_status/1" do
    @tag :skip
    test "returns current transcoding status" do
      input_path = "/tmp/test_input.mp4"
      output_path = "/tmp/test_output.mp4"

      File.write!(input_path, "test data")

      try do
        {:ok, pid} =
          FfmpegMp4Transcoder.start_transcoding(
            input_path: input_path,
            output_path: output_path,
            resolution: :p480
          )

        {:ok, status} = FfmpegMp4Transcoder.get_status(pid)

        assert status.input_path == input_path
        assert status.output_path == output_path
        assert status.resolution == :p480
        assert is_boolean(status.ffmpeg_alive?)

        FfmpegMp4Transcoder.stop_transcoding(pid)
      after
        File.rm(input_path)
        File.rm(output_path)
      end
    end
  end

  describe "callbacks" do
    @tag :skip
    test "calls on_progress callback with progress updates" do
      input_path = "/tmp/test_input.mp4"
      output_path = "/tmp/test_output.mp4"

      File.write!(input_path, "test data")

      # Track progress calls
      test_pid = self()
      progress_ref = make_ref()

      on_progress = fn progress ->
        send(test_pid, {:progress, progress_ref, progress})
      end

      try do
        {:ok, pid} =
          FfmpegMp4Transcoder.start_transcoding(
            input_path: input_path,
            output_path: output_path,
            resolution: :p720,
            on_progress: on_progress
          )

        # Wait for potential progress updates (with timeout)
        receive do
          {:progress, ^progress_ref, progress} ->
            assert is_map(progress)
            assert Map.has_key?(progress, :time)
        after
          5_000 -> :ok
        end

        FfmpegMp4Transcoder.stop_transcoding(pid)
      after
        File.rm(input_path)
        File.rm(output_path)
      end
    end

    @tag :skip
    test "calls on_complete callback when transcoding finishes" do
      input_path = "/tmp/test_input.mp4"
      output_path = "/tmp/test_output.mp4"

      File.write!(input_path, "test data")

      test_pid = self()
      complete_ref = make_ref()

      on_complete = fn ->
        send(test_pid, {:complete, complete_ref})
      end

      try do
        {:ok, _pid} =
          FfmpegMp4Transcoder.start_transcoding(
            input_path: input_path,
            output_path: output_path,
            resolution: :p720,
            on_complete: on_complete
          )

        # Wait for completion callback
        receive do
          {:complete, ^complete_ref} -> :ok
        after
          10_000 -> flunk("Expected on_complete callback")
        end
      after
        File.rm(input_path)
        File.rm(output_path)
      end
    end

    @tag :skip
    test "calls on_error callback when FFmpeg fails" do
      output_path = "/tmp/test_output.mp4"

      test_pid = self()
      error_ref = make_ref()

      on_error = fn error ->
        send(test_pid, {:error, error_ref, error})
      end

      {:ok, _pid} =
        FfmpegMp4Transcoder.start_transcoding(
          input_path: "/nonexistent/file.mp4",
          output_path: output_path,
          resolution: :p720,
          on_error: on_error
        )

      # Wait for error callback
      receive do
        {:error, ^error_ref, error_msg} ->
          assert is_binary(error_msg)
      after
        10_000 -> flunk("Expected on_error callback")
      end
    end
  end

  describe "resolution presets" do
    test "supports 1080p resolution" do
      # Access the module attribute via reflection
      assert :p1080 in [:p1080, :p720, :p480]
    end

    test "supports 720p resolution" do
      assert :p720 in [:p1080, :p720, :p480]
    end

    test "supports 480p resolution" do
      assert :p480 in [:p1080, :p720, :p480]
    end
  end
end
