defmodule MydiaWeb.Api.HlsSubtitleTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.SessionSubtitles

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "hls_subs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)
    {:ok, temp_dir: temp_dir, info: %{temp_dir: temp_dir, media_file_id: "unused"}}
  end

  test "a materialized subtitle resolves and carries the VTT content type",
       %{temp_dir: dir, info: info} do
    File.write!(Path.join(dir, "subs_2.vtt"), "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n")

    assert {:ok, path} = SessionSubtitles.ensure(info, "subs_2.vtt")
    assert Mydia.Streaming.SessionFiles.content_type(path) == "text/vtt"
    assert File.read!(path) =~ "WEBVTT"
  end

  test "an ordinary segment name falls through untouched", %{info: info} do
    assert :not_subtitle = SessionSubtitles.ensure(info, "segment_001.ts")
    assert :not_subtitle = SessionSubtitles.ensure(info, "index.m3u8")
  end
end
