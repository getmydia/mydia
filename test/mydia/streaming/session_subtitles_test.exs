defmodule Mydia.Streaming.SessionSubtitlesTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.SessionSubtitles

  describe "filename/1" do
    test "names an embedded track by its stream index" do
      assert SessionSubtitles.filename(3) == "subs_3.vtt"
    end

    test "names a sidecar track by its uuid" do
      uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
      assert SessionSubtitles.filename(uuid) == "subs_#{uuid}.vtt"
    end
  end

  describe "track_id_from_filename/1" do
    test "reads an integer track id back as an integer" do
      assert {:ok, 3} = SessionSubtitles.track_id_from_filename("subs_3.vtt")
    end

    test "reads a uuid track id back as a string" do
      uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
      assert {:ok, ^uuid} = SessionSubtitles.track_id_from_filename("subs_#{uuid}.vtt")
    end

    test "round-trips every shape filename/1 produces" do
      for id <- [0, 3, 42, "0f8fad5b-d9cb-469f-a165-70867728950e"] do
        assert {:ok, ^id} = SessionSubtitles.track_id_from_filename(SessionSubtitles.filename(id))
      end
    end

    # Anything that is not a subtitle name must fall through to the existing
    # segment logic untouched, so this returns :error rather than raising.
    test "rejects names that are not subtitle files" do
      assert :error = SessionSubtitles.track_id_from_filename("index.m3u8")
      assert :error = SessionSubtitles.track_id_from_filename("segment_001.ts")
      assert :error = SessionSubtitles.track_id_from_filename("subs_.vtt")
      assert :error = SessionSubtitles.track_id_from_filename("subs_3.srt")
      assert :error = SessionSubtitles.track_id_from_filename("subs_../../etc/passwd.vtt")
      assert :error = SessionSubtitles.track_id_from_filename("subs_3.vtt.exe")
    end
  end

  describe "ensure/2" do
    setup do
      temp_dir =
        Path.join(System.tmp_dir!(), "session_subs_#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)
      {:ok, temp_dir: temp_dir}
    end

    test "returns :not_subtitle for a name that is not a subtitle file", %{temp_dir: dir} do
      info = %{temp_dir: dir, media_file_id: "irrelevant"}
      assert :not_subtitle = SessionSubtitles.ensure(info, "segment_001.ts")
    end

    test "returns an already-materialized file without touching the media file",
         %{temp_dir: dir} do
      # media_file_id is deliberately bogus: a cache hit must not load it.
      File.write!(Path.join(dir, "subs_3.vtt"), "WEBVTT\n\n")
      info = %{temp_dir: dir, media_file_id: "no-such-file"}

      assert {:ok, path} = SessionSubtitles.ensure(info, "subs_3.vtt")
      assert File.read!(path) == "WEBVTT\n\n"
    end

    test "refuses a traversal attempt dressed as a subtitle name", %{temp_dir: dir} do
      info = %{temp_dir: dir, media_file_id: "irrelevant"}
      assert :not_subtitle = SessionSubtitles.ensure(info, "../subs_3.vtt")
    end
  end
end
