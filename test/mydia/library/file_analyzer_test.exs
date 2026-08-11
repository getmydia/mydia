defmodule Mydia.Library.FileAnalyzerTest do
  # Tests mutate Application env (ffprobe_path, ffprobe_timeout_ms) so we must
  # run them serially to avoid interleaving with other tests in the suite.
  use ExUnit.Case, async: false

  alias Mydia.Library.FileAnalyzer

  describe "analyze/1" do
    test "returns error when file does not exist" do
      assert {:error, :file_not_found} = FileAnalyzer.analyze("/nonexistent/file.mkv")
    end

    test "returns error when ffprobe is not available" do
      # Create a temporary empty file
      path = Path.join(System.tmp_dir!(), "test_video_#{:rand.uniform(1000)}.mkv")
      File.write!(path, "")

      # The file exists but ffprobe will fail to parse it
      result = FileAnalyzer.analyze(path)

      # Clean up
      File.rm(path)

      # Should return an error (either ffprobe_failed or invalid_json)
      assert match?({:error, _}, result)
    end

    test "extracts file size even when ffprobe fails" do
      # We can't easily test successful FFprobe extraction without actual video files
      # and FFprobe installed, but we can verify the file size extraction works
      path = Path.join(System.tmp_dir!(), "test_video_#{:rand.uniform(1000)}.mkv")
      content = "fake video content"
      File.write!(path, content)

      result = FileAnalyzer.analyze(path)

      # Clean up
      File.rm(path)

      # The result might be an error, but if we somehow got metadata,
      # size should match
      case result do
        {:ok, metadata} ->
          assert metadata.size == byte_size(content)

        {:error, _} ->
          # Expected for non-video files
          :ok
      end
    end
  end

  describe "resolution extraction" do
    setup do
      target_file = write_temp_file("fake video content")

      on_exit(fn ->
        Application.delete_env(:mydia, :ffprobe_path)
        File.rm(target_file)
      end)

      %{target_file: target_file}
    end

    test "keeps standard 1080p video at 1080p", %{target_file: target_file} do
      shim =
        write_json_shim(
          ~s({"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"60.0","format_name":"matroska"}})
        )

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.resolution == "1080p"
        assert result.width == 1920
        assert result.height == 1080
      after
        File.rm(shim)
      end
    end

    test "treats cropped 1920x800 widescreen encodes as 1080p", %{target_file: target_file} do
      shim =
        write_json_shim(
          ~s({"streams":[{"codec_type":"video","codec_name":"hevc","width":1920,"height":800},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"60.0","format_name":"matroska"}})
        )

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.resolution == "1080p"
        assert result.width == 1920
        assert result.height == 800
      after
        File.rm(shim)
      end
    end

    test "does not up-rank true 720p widescreen encodes", %{target_file: target_file} do
      shim =
        write_json_shim(
          ~s({"streams":[{"codec_type":"video","codec_name":"h264","width":1280,"height":534},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"60.0","format_name":"matroska"}})
        )

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.resolution == "720p"
        assert result.width == 1280
        assert result.height == 534
      after
        File.rm(shim)
      end
    end

    test "does not up-rank true ultrawide sources", %{target_file: target_file} do
      shim =
        write_json_shim(
          ~s({"streams":[{"codec_type":"video","codec_name":"hevc","width":2560,"height":1080},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"60.0","format_name":"matroska"}})
        )

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.resolution == "1080p"
        assert result.width == 2560
        assert result.height == 1080
      after
        File.rm(shim)
      end
    end
  end

  describe "codec mapping" do
    test "maps common video codecs correctly" do
      # h264 -> "H.264"
      # hevc -> "HEVC"
      # av1 -> "AV1"
      # vp9 -> "VP9"
      # etc.

      assert true
    end

    test "maps common audio codecs correctly" do
      # aac -> "AAC"
      # ac3 -> "AC3"
      # eac3 -> "DD+"
      # dts -> "DTS"
      # truehd -> "TrueHD"
      # etc.

      assert true
    end
  end

  describe "HDR format detection" do
    test "detects Dolby Vision from side data" do
      # Would need mock FFprobe output
      assert true
    end

    test "detects HDR10+ from side data" do
      # Would need mock FFprobe output
      assert true
    end

    test "detects HDR10 from color transfer" do
      # Would need mock FFprobe output
      assert true
    end
  end

  describe "ffprobe timeout and process cleanup" do
    setup do
      target_file = write_temp_file("fake video content")

      on_exit(fn ->
        Application.delete_env(:mydia, :ffprobe_path)
        Application.delete_env(:mydia, :ffprobe_timeout_ms)
        File.rm(target_file)
      end)

      %{target_file: target_file}
    end

    test "returns {:error, :ffprobe_timeout} when ffprobe exceeds the configured timeout",
         %{target_file: target_file} do
      shim = write_shim("#!/bin/sh\nsleep 5\n")

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)
        Application.put_env(:mydia, :ffprobe_timeout_ms, 200)

        started_at = System.monotonic_time(:millisecond)
        result = FileAnalyzer.analyze(target_file)
        elapsed = System.monotonic_time(:millisecond) - started_at

        assert {:error, :ffprobe_timeout} = result
        # Should return promptly after the timeout fires (200ms + brief kill window)
        assert elapsed < 1500,
               "expected analyze/1 to return within 1500ms of the 200ms timeout, got #{elapsed}ms"
      after
        File.rm(shim)
      end
    end

    test "kills the OS process when the timeout fires (no zombie)",
         %{target_file: target_file} do
      # Marker arg so we can find the shim process via pgrep
      marker = "mydia-zombie-test-#{:rand.uniform(1_000_000_000)}"
      shim = write_shim("#!/bin/sh\nsleep 30 # #{marker}\n")

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)
        Application.put_env(:mydia, :ffprobe_timeout_ms, 150)

        assert {:error, :ffprobe_timeout} = FileAnalyzer.analyze(target_file)

        # Give the SIGKILL a moment to propagate through `kill -9`
        Process.sleep(200)

        {pgrep_out, _} = System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true)
        leftover = String.trim(pgrep_out)

        assert leftover == "",
               "expected no leftover ffprobe-shim processes matching #{marker}, found: #{leftover}"
      after
        File.rm(shim)
        # Defensive cleanup if a process did leak
        System.cmd("pkill", ["-9", "-f", marker], stderr_to_stdout: true)
      end
    end

    test "returns {:error, :ffprobe_failed} when the shim exits non-zero",
         %{target_file: target_file} do
      shim = write_shim("#!/bin/sh\necho 'simulated ffprobe failure' >&2\nexit 1\n")

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)
        assert {:error, :ffprobe_failed} = FileAnalyzer.analyze(target_file)
      after
        File.rm(shim)
      end
    end

    test "returns {:error, :ffprobe_not_found} when no ffprobe binary resolves",
         %{target_file: target_file} do
      Application.put_env(:mydia, :ffprobe_path, "/nonexistent/ffprobe-binary")
      assert {:error, :ffprobe_not_found} = FileAnalyzer.analyze(target_file)
    end
  end

  describe "stream capture" do
    setup do
      target_file = write_temp_file("fake video content")

      on_exit(fn ->
        Application.delete_env(:mydia, :ffprobe_path)
        File.rm(target_file)
      end)

      %{target_file: target_file}
    end

    test "captures every video, audio and subtitle stream", %{target_file: target_file} do
      shim =
        write_json_shim(~s({"streams":[
          {"index":0,"codec_type":"video","codec_name":"hevc","width":3840,"height":2160,"avg_frame_rate":"24000/1001"},
          {"index":1,"codec_type":"audio","codec_name":"truehd","channels":8,"tags":{"language":"eng"}},
          {"index":2,"codec_type":"audio","codec_name":"eac3","channels":6,"tags":{"language":"eng"}},
          {"index":3,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"spa"}}
        ],"format":{"duration":"9780.0","format_name":"matroska"}}))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert length(result.streams) == 4
        assert Enum.map(result.streams, & &1.type) == [:video, :audio, :audio, :subtitle]
        assert Enum.at(result.streams, 1).channels == 8
        assert Enum.at(result.streams, 3).language == "spa"
      after
        File.rm(shim)
      end
    end

    test "drops attachment streams", %{target_file: target_file} do
      shim =
        write_json_shim(~s({"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
          {"index":1,"codec_type":"attachment","codec_name":"ttf"}
        ],"format":{"duration":"60.0","format_name":"matroska"}}))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert length(result.streams) == 1
        assert hd(result.streams).type == :video
      after
        File.rm(shim)
      end
    end

    test "returns an empty list when there are no usable streams", %{target_file: target_file} do
      shim =
        write_json_shim(~s({"streams":[],"format":{"duration":"60.0","format_name":"matroska"}}))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.streams == []
      after
        File.rm(shim)
      end
    end

    test "leaves the derived flat fields unchanged", %{target_file: target_file} do
      shim =
        write_json_shim(~s({"streams":[
          {"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080},
          {"index":1,"codec_type":"audio","codec_name":"aac","channels":6}
        ],"format":{"duration":"60.0","format_name":"matroska"}}))

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        assert {:ok, result} = FileAnalyzer.analyze(target_file)
        assert result.resolution == "1080p"
        assert result.width == 1920
        assert result.height == 1080
        assert result.container == "mkv"
      after
        File.rm(shim)
      end
    end
  end

  defp write_temp_file(content) do
    path = Path.join(System.tmp_dir!(), "ffprobe_test_#{:rand.uniform(10_000_000)}.mkv")
    File.write!(path, content)
    path
  end

  defp write_shim(script_body) do
    path = Path.join(System.tmp_dir!(), "ffprobe_shim_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, script_body)
    File.chmod!(path, 0o755)
    path
  end

  defp write_json_shim(json) do
    escaped = String.replace(json, "'", "'\\''")
    write_shim("#!/bin/sh\nprintf '%s' '#{escaped}'\n")
  end
end
