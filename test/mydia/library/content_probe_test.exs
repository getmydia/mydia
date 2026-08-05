defmodule Mydia.Library.ContentProbeTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ContentProbe

  @moduletag :tmp_dir

  test "reports not_media for a file ffprobe cannot parse", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "fake.exe")
    File.write!(path, "MZ" <> :binary.copy(<<0>>, 4096))

    assert %{"status" => "not_media", "detail" => detail} = ContentProbe.probe(path)
    assert is_binary(detail)
  end

  test "reports unknown for a file that does not exist", %{tmp_dir: tmp_dir} do
    assert %{"status" => "unknown"} = ContentProbe.probe(Path.join(tmp_dir, "gone.mkv"))
  end

  @tag :requires_ffmpeg
  test "reports media for a real video file", %{tmp_dir: tmp_dir} do
    if System.find_executable("ffmpeg") do
      video_path = create_test_video(tmp_dir)

      assert %{"status" => "media", "detail" => detail} = ContentProbe.probe(video_path)
      assert is_binary(detail) and detail != ""
    else
      IO.puts("Skipping test: ffmpeg not available")
      assert true
    end
  end

  # Generates a real, tiny video so classify/1, parse_fields/1, has_av_stream?/1,
  # and summarize/1 are exercised against actual ffprobe output instead of only
  # the not_media/unknown paths. Mirrors
  # ThumbnailGeneratorTest.create_test_video/0.
  defp create_test_video(tmp_dir) do
    video_path = Path.join(tmp_dir, "test_video.mp4")

    args = [
      "-f",
      "lavfi",
      "-i",
      "color=c=blue:s=320x240:d=1",
      "-c:v",
      "libx264",
      "-t",
      "1",
      "-y",
      video_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} -> video_path
      {output, _} -> raise "Failed to create test video: #{output}"
    end
  end
end
