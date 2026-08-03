defmodule Mydia.Library.FfmpegTest do
  # Mutates Application env for the binary path, so serial.
  use ExUnit.Case, async: false

  alias Mydia.Library.Ffmpeg

  setup do
    on_exit(fn ->
      Application.delete_env(:mydia, :ffmpeg_path)
      Application.delete_env(:mydia, :ffprobe_path)
    end)

    :ok
  end

  describe "run/1" do
    test "returns the combined output on success" do
      assert {:ok, output} = Ffmpeg.run(["-version"])
      assert output =~ "ffmpeg version"
    end

    test "returns a structured error with exit code and output on failure" do
      assert {:error, {:ffmpeg_error, code, output}} =
               Ffmpeg.run(["-i", "/nonexistent/definitely-not-here.mkv", "-f", "null", "-"])

      assert is_integer(code)
      assert code != 0
      assert is_binary(output)
    end

    test "returns :ffmpeg_not_found when the binary is missing" do
      Application.put_env(:mydia, :ffmpeg_path, "/nonexistent/ffmpeg-binary")

      assert {:error, :ffmpeg_not_found} = Ffmpeg.run(["-version"])
    end
  end

  describe "probe/1" do
    test "returns the combined output on success" do
      assert {:ok, output} = Ffmpeg.probe(["-version"])
      assert output =~ "ffprobe version"
    end

    test "returns :ffprobe_not_found when the binary is missing" do
      Application.put_env(:mydia, :ffprobe_path, "/nonexistent/ffprobe-binary")

      assert {:error, :ffprobe_not_found} = Ffmpeg.probe(["-version"])
    end
  end
end
