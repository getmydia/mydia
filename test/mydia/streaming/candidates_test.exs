defmodule Mydia.Streaming.CandidatesTest do
  # Tests mutate Application env (ffprobe_path) so we run them serially.
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Streaming.Candidates

  setup do
    on_exit(fn ->
      Application.delete_env(:mydia, :ffprobe_path)
      Application.delete_env(:mydia, :ffprobe_timeout_ms)
      Application.delete_env(:mydia, :file_analysis_max_attempts)
    end)

    :ok
  end

  describe "ensure_codec_info/1 (U6 lazy fallback)" do
    test "analyzed_at IS NULL row triggers inline ffprobe and persists the result" do
      {media_file, target} = seed_unanalyzed("u6_lazy_happy")
      shim = write_ok_shim(File.stat!(target).size)

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        refreshed = Candidates.ensure_codec_info(media_file)

        assert refreshed.codec == "h264"
        assert refreshed.audio_codec == "aac"
        assert refreshed.resolution == "1080p"
        assert %DateTime{} = refreshed.analyzed_at

        reloaded = Repo.get!(MediaFile, media_file.id)
        assert %DateTime{} = reloaded.analyzed_at
        assert reloaded.codec == "h264"
      after
        File.rm(shim)
        File.rm(target)
      end
    end

    test "already-analyzed row is returned unchanged and ffprobe is not invoked" do
      {media_file, target} = seed_unanalyzed("u6_lazy_already")

      # Mark the row analyzed without running ffprobe so we can assert the
      # shim is never invoked.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^media_file.id),
        set: [
          analyzed_at: now,
          codec: "h264",
          audio_codec: "aac",
          resolution: "1080p"
        ]
      )

      media_file =
        Repo.get!(MediaFile, media_file.id)
        |> Repo.preload(:library_path)

      # Point ffprobe at /bin/false; if ensure_codec_info calls it, the test
      # would fail because /bin/false exits non-zero and the row's
      # analyzed_at would be replaced. Loud failure makes the assertion crisp.
      Application.put_env(:mydia, :ffprobe_path, "/bin/false")

      try do
        result = Candidates.ensure_codec_info(media_file)

        assert result.codec == "h264"
        assert result.analyzed_at == media_file.analyzed_at
      after
        File.rm(target)
      end
    end

    test "row past the attempt ceiling is not retried by the lazy path" do
      Application.put_env(:mydia, :file_analysis_max_attempts, 3)
      {media_file, target} = seed_unanalyzed("u6_lazy_ceiling")

      Repo.update_all(
        from(mf in MediaFile, where: mf.id == ^media_file.id),
        set: [analysis_attempts: 3, last_analysis_error: ":ffprobe_timeout"]
      )

      media_file =
        Repo.get!(MediaFile, media_file.id)
        |> Repo.preload(:library_path)

      Application.put_env(:mydia, :ffprobe_path, "/bin/false")

      try do
        result = Candidates.ensure_codec_info(media_file)

        assert is_nil(result.codec)
        assert is_nil(result.analyzed_at)

        reloaded = Repo.get!(MediaFile, media_file.id)
        # Counter should NOT have been bumped on this lazy call.
        assert reloaded.analysis_attempts == 3
      after
        File.rm(target)
      end
    end

    test "ffprobe failure bumps analysis_attempts and returns media_file unchanged" do
      {media_file, target} = seed_unanalyzed("u6_lazy_fail")
      shim = write_fail_shim()

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        result = Candidates.ensure_codec_info(media_file)

        # Returns the original media_file (no inline mutation on error).
        assert is_nil(result.codec)
        assert is_nil(result.analyzed_at)

        reloaded = Repo.get!(MediaFile, media_file.id)
        assert reloaded.analysis_attempts == 1
        assert reloaded.last_analysis_error == ":ffprobe_failed"
      after
        File.rm(shim)
        File.rm(target)
      end
    end

    test "concurrent lazy probes on the same row are race-safe (AE6)" do
      {media_file, target} = seed_unanalyzed("u6_lazy_race")
      shim = write_ok_shim(File.stat!(target).size)

      try do
        Application.put_env(:mydia, :ffprobe_path, shim)

        # Fire two concurrent lazy probes. Each is its own database
        # connection (via the sandbox parent below). The :already_analyzed
        # short-circuit in apply_analysis/2 must prevent a second overwrite.
        parent = self()
        Ecto.Adapters.SQL.Sandbox.allow(Mydia.Repo, parent, parent)

        Ecto.Adapters.SQL.Sandbox.mode(Mydia.Repo, {:shared, parent})

        results =
          1..2
          |> Enum.map(fn _ ->
            Task.async(fn ->
              Candidates.ensure_codec_info(media_file)
            end)
          end)
          |> Task.await_many(5_000)

        for r <- results do
          assert r.codec == "h264"
        end

        reloaded = Repo.get!(MediaFile, media_file.id)
        assert %DateTime{} = reloaded.analyzed_at
      after
        Ecto.Adapters.SQL.Sandbox.mode(Mydia.Repo, :manual)
        File.rm(shim)
        File.rm(target)
      end
    end

    test "missing absolute path falls through without calling ffprobe" do
      library_path = library_path_fixture(%{path: "/u6-no-path", type: "movies"})

      {:ok, media_file} =
        Library.create_scanned_media_file(%{
          relative_path: "nonexistent.mkv",
          library_path_id: library_path.id,
          size: 1_000_000
        })

      media_file = Repo.preload(media_file, :library_path)

      Application.put_env(:mydia, :ffprobe_path, "/bin/false")

      result = Candidates.ensure_codec_info(media_file)
      assert result.id == media_file.id
      assert is_nil(result.analyzed_at)
    end
  end

  describe "resolve_media_file/2 file selection" do
    test "a movie resolves to its highest-resolution file, whichever was created first" do
      hd_first = media_item_fixture(%{type: "movie"})
      _hd = media_file_fixture(%{media_item_id: hd_first.id, resolution: "1080p"})
      uhd = media_file_fixture(%{media_item_id: hd_first.id, resolution: "4K"})

      uhd_first = media_item_fixture(%{type: "movie"})
      uhd2 = media_file_fixture(%{media_item_id: uhd_first.id, resolution: "4K"})
      _hd2 = media_file_fixture(%{media_item_id: uhd_first.id, resolution: "1080p"})

      assert {:ok, chosen} = Candidates.resolve_media_file("movie", hd_first.id)
      assert chosen.id == uhd.id

      assert {:ok, chosen2} = Candidates.resolve_media_file("movie", uhd_first.id)
      assert chosen2.id == uhd2.id
    end

    test "an episode resolves to its highest-resolution file" do
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})

      _hd = media_file_fixture(%{episode_id: episode.id, resolution: "720p"})
      uhd = media_file_fixture(%{episode_id: episode.id, resolution: "2160p"})

      assert {:ok, chosen} = Candidates.resolve_media_file("episode", episode.id)
      assert chosen.id == uhd.id
    end

    test "a resolution tie falls through to bitrate" do
      movie = media_item_fixture(%{type: "movie"})

      _low =
        media_file_fixture(%{media_item_id: movie.id, resolution: "1080p", bitrate: 4_000_000})

      high =
        media_file_fixture(%{media_item_id: movie.id, resolution: "1080p", bitrate: 15_000_000})

      assert {:ok, chosen} = Candidates.resolve_media_file("movie", movie.id)
      assert chosen.id == high.id
    end

    test "an unanalyzed file never wins over one with a known resolution" do
      movie = media_item_fixture(%{type: "movie"})

      _unknown =
        media_file_fixture(%{
          media_item_id: movie.id,
          resolution: nil,
          bitrate: 99_000_000
        })

      known = media_file_fixture(%{media_item_id: movie.id, resolution: "480p"})

      assert {:ok, chosen} = Candidates.resolve_media_file("movie", movie.id)
      assert chosen.id == known.id
    end

    test "content_type \"file\" returns that exact file even when a better sibling exists" do
      movie = media_item_fixture(%{type: "movie"})

      hd = media_file_fixture(%{media_item_id: movie.id, resolution: "1080p"})
      _uhd = media_file_fixture(%{media_item_id: movie.id, resolution: "4K"})

      # This is the path the fixed player takes. It must never re-rank.
      assert {:ok, chosen} = Candidates.resolve_media_file("file", hd.id)
      assert chosen.id == hd.id
    end

    test "trashed files are excluded from ranking" do
      movie = media_item_fixture(%{type: "movie"})

      hd = media_file_fixture(%{media_item_id: movie.id, resolution: "1080p"})

      _trashed_uhd =
        media_file_fixture(%{
          media_item_id: movie.id,
          resolution: "4K",
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:ok, chosen} = Candidates.resolve_media_file("movie", movie.id)
      assert chosen.id == hd.id
    end

    test "a movie with no files reports :no_media_files" do
      movie = media_item_fixture(%{type: "movie"})
      assert {:error, :no_media_files} = Candidates.resolve_media_file("movie", movie.id)
    end

    test "a malformed id reports :not_found instead of raising" do
      # binary_id primary keys reject anything that doesn't parse as a UUID
      # with Ecto.Query.CastError, not Ecto.NoResultsError. The player sends
      # the literal string "offline" here when a downloaded file's local
      # copy has gone missing and playback falls through to streaming — that
      # has to come back as a clean not-found, not a crash report.
      assert {:error, :not_found} = Candidates.resolve_media_file("file", "not-a-uuid")
      assert {:error, :not_found} = Candidates.resolve_media_file("movie", "not-a-uuid")
      assert {:error, :not_found} = Candidates.resolve_media_file("episode", "not-a-uuid")
    end
  end

  # Helpers

  defp seed_unanalyzed(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)

    relative = "subject.mkv"
    target = Path.join(dir, relative)
    File.write!(target, "fake video bytes")

    library_path = library_path_fixture(%{path: dir, type: "movies"})

    {:ok, media_file} =
      Library.create_scanned_media_file(%{
        relative_path: relative,
        library_path_id: library_path.id,
        size: File.stat!(target).size
      })

    media_file = Repo.preload(media_file, :library_path)
    {media_file, target}
  end

  defp write_ok_shim(size) do
    json =
      ~s({"streams":[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"bit_rate":"8000000"},{"codec_type":"audio","codec_name":"aac"}],"format":{"duration":"5400.5","format_name":"matroska,webm","size":"#{size}","bit_rate":"8000000"}})

    path = Path.join(System.tmp_dir!(), "u6_ffprobe_ok_#{:rand.uniform(10_000_000)}.sh")
    escaped = String.replace(json, "'", "'\\''")
    File.write!(path, "#!/bin/sh\nprintf '%s' '#{escaped}'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp write_fail_shim do
    path = Path.join(System.tmp_dir!(), "u6_ffprobe_fail_#{:rand.uniform(10_000_000)}.sh")
    File.write!(path, "#!/bin/sh\necho 'simulated failure' >&2\nexit 1\n")
    File.chmod!(path, 0o755)
    path
  end
end
