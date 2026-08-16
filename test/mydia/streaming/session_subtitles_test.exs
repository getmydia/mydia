defmodule Mydia.Streaming.SessionSubtitlesTest do
  use Mydia.DataCase, async: false

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Streaming.SessionSubtitles
  alias Mydia.Subtitles.Subtitle

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

    # A bare `$` in PCRE matches just before a single trailing newline, not
    # only true end-of-string, so "subs_3.vtt\n" would slip past a pattern
    # anchored with `$` instead of `\z`. A leading newline is already refused
    # by `^` (which only ever anchors to the true start of the subject, with
    # no multiline flag set), but is asserted here too as a regression guard.
    test "rejects a name carrying a trailing or leading newline" do
      assert :error = SessionSubtitles.track_id_from_filename("subs_3.vtt\n")
      assert :error = SessionSubtitles.track_id_from_filename("\nsubs_3.vtt")
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

    # "../subs_3.vtt" never reaches SessionFiles.safe_path/2: it is rejected by
    # the filename regex itself, because it does not start with "subs_". The
    # {:error, :path_traversal} branch in ensure/2 is unreachable by
    # construction while that regex holds (see the comment on that clause);
    # this test covers the regex rejection, not the path-validation branch.
    test "rejects a traversal-shaped name via the filename regex", %{temp_dir: dir} do
      info = %{temp_dir: dir, media_file_id: "irrelevant"}
      assert :not_subtitle = SessionSubtitles.ensure(info, "../subs_3.vtt")
    end
  end

  describe "ensure/2 through materialize/3" do
    setup do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "session_subs_materialize_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)
      {:ok, temp_dir: temp_dir}
    end

    test "refuses an image-format embedded track and writes nothing", %{temp_dir: dir} do
      media_file =
        MediaFixtures.media_file_fixture(%{
          metadata: %FileMetadata{
            streams: [
              %StreamInfo{index: 3, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "spa"}
            ]
          }
        })
        |> Repo.preload(:library_path)

      info = %{temp_dir: dir, media_file_id: media_file.id}
      name = SessionSubtitles.filename(3)

      assert {:error, :image_subtitle} = SessionSubtitles.ensure(info, name)
      refute File.exists?(Path.join(dir, name))
    end

    test "materializes a sidecar track as WebVTT at the expected path", %{temp_dir: dir} do
      media_file =
        MediaFixtures.media_file_fixture(%{metadata: %FileMetadata{streams: []}})
        |> Repo.preload(:library_path)

      sub_dir =
        Path.join(System.tmp_dir!(), "session_subs_sidecar_#{System.unique_integer([:positive])}")

      File.mkdir_p!(sub_dir)
      on_exit(fn -> File.rm_rf(sub_dir) end)

      srt_path = Path.join(sub_dir, "sub.en.srt")

      File.write!(srt_path, """
      1
      00:00:01,000 --> 00:00:04,000
      Hello there.
      """)

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          format: "srt",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: srt_path,
          provider: "relay"
        })
        |> Repo.insert()

      info = %{temp_dir: dir, media_file_id: media_file.id}
      name = SessionSubtitles.filename(subtitle.id)
      expected_path = Path.join(dir, name)

      assert {:ok, ^expected_path} = SessionSubtitles.ensure(info, name)

      content = File.read!(expected_path)
      assert String.starts_with?(content, "WEBVTT")
      assert content =~ "00:00:01.000 --> 00:00:04.000"
      assert content =~ "Hello there."
    end

    # Two concurrent callers asking for the same uncached track must not both
    # win independently. What this proves: both callers get {:ok, path}, the
    # path is identical, and the file's final content is the one correct
    # conversion — i.e. concurrent access is safe and does not corrupt or
    # race the write. What it does NOT prove: that Delivery.content/3 (or an
    # ffmpeg extraction) ran exactly once. Observing that from outside would
    # mean instrumenting production code just to make it observable, which
    # the actual locking behaviour (grant/wait/hand-off) is not — that
    # guarantee is covered by Mydia.Plugins.SingleFlightTest, which this
    # module delegates to rather than reimplementing.
    test "two concurrent callers for the same uncached track both resolve safely", %{
      temp_dir: dir
    } do
      media_file =
        MediaFixtures.media_file_fixture(%{metadata: %FileMetadata{streams: []}})
        |> Repo.preload(:library_path)

      sub_dir =
        Path.join(
          System.tmp_dir!(),
          "session_subs_sidecar_concurrent_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(sub_dir)
      on_exit(fn -> File.rm_rf(sub_dir) end)

      srt_path = Path.join(sub_dir, "sub.en.srt")

      File.write!(srt_path, """
      1
      00:00:01,000 --> 00:00:04,000
      Hello there.
      """)

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          format: "srt",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: srt_path,
          provider: "relay"
        })
        |> Repo.insert()

      info = %{temp_dir: dir, media_file_id: media_file.id}
      name = SessionSubtitles.filename(subtitle.id)
      expected_path = Path.join(dir, name)

      [result_a, result_b] =
        [
          Task.async(fn -> SessionSubtitles.ensure(info, name) end),
          Task.async(fn -> SessionSubtitles.ensure(info, name) end)
        ]
        |> Task.await_many()

      assert {:ok, ^expected_path} = result_a
      assert {:ok, ^expected_path} = result_b
      assert File.exists?(expected_path)

      content = File.read!(expected_path)
      assert String.starts_with?(content, "WEBVTT")
      assert content =~ "Hello there."
    end

    # These two tests establish the pieces of the atomic-write property that
    # can honestly be observed from outside `materialize/3` without
    # instrumenting production code to make an in-flight write visible:
    # a write that fails leaves nothing at the final path (so `ensure/2`'s
    # File.exists?/1 fast path can never find a broken file), and a write
    # that succeeds always leaves complete content there. What this does
    # *not* prove is the actual interleaving described in the finding — a
    # concurrent reader observing a half-written file mid-`File.write/2` —
    # because that race is a timing property of the old code, not something
    # a deterministic test can force without changing production code to be
    # instrumentable. The "two concurrent callers" test above covers the
    # only interleaving that unit tests can exercise (both through the lock).
    test "a write that fails to reach disk leaves no file at the final path", %{
      temp_dir: _dir
    } do
      media_file =
        MediaFixtures.media_file_fixture(%{metadata: %FileMetadata{streams: []}})
        |> Repo.preload(:library_path)

      sub_dir =
        Path.join(
          System.tmp_dir!(),
          "session_subs_sidecar_writefail_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(sub_dir)
      on_exit(fn -> File.rm_rf(sub_dir) end)

      srt_path = Path.join(sub_dir, "sub.en.srt")

      File.write!(srt_path, """
      1
      00:00:01,000 --> 00:00:04,000
      Hello there.
      """)

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          format: "srt",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: srt_path,
          provider: "relay"
        })
        |> Repo.insert()

      # A temp_dir that does not exist on disk makes the temp-file write
      # itself fail with :enoent, deterministically and without touching
      # `atomic_write/2` or `materialize/3` — `SessionFiles.safe_path/2` only
      # does string/path-expansion work, so it never requires the directory
      # to exist.
      missing_dir =
        Path.join(
          System.tmp_dir!(),
          "session_subs_missing_#{System.unique_integer([:positive])}"
        )

      info = %{temp_dir: missing_dir, media_file_id: media_file.id}
      name = SessionSubtitles.filename(subtitle.id)
      expected_path = Path.join(missing_dir, name)

      assert {:error, _reason} = SessionSubtitles.ensure(info, name)
      refute File.exists?(expected_path)
    end

    test "a completed write is never partial: the final file is complete WebVTT",
         %{temp_dir: dir} do
      media_file =
        MediaFixtures.media_file_fixture(%{metadata: %FileMetadata{streams: []}})
        |> Repo.preload(:library_path)

      sub_dir =
        Path.join(
          System.tmp_dir!(),
          "session_subs_sidecar_complete_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(sub_dir)
      on_exit(fn -> File.rm_rf(sub_dir) end)

      srt_path = Path.join(sub_dir, "sub.en.srt")

      File.write!(srt_path, """
      1
      00:00:01,000 --> 00:00:04,000
      Hello there.

      2
      00:00:05,000 --> 00:00:08,000
      Goodbye.
      """)

      {:ok, subtitle} =
        %Subtitle{}
        |> Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          format: "srt",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: srt_path,
          provider: "relay"
        })
        |> Repo.insert()

      info = %{temp_dir: dir, media_file_id: media_file.id}
      name = SessionSubtitles.filename(subtitle.id)
      expected_path = Path.join(dir, name)

      assert {:ok, ^expected_path} = SessionSubtitles.ensure(info, name)

      content = File.read!(expected_path)
      assert String.starts_with?(content, "WEBVTT")
      assert content =~ "Hello there."
      assert content =~ "Goodbye."

      # No orphaned temp file left behind alongside the final one.
      refute dir
             |> File.ls!()
             |> Enum.any?(&String.contains?(&1, ".tmp-"))
    end
  end
end
