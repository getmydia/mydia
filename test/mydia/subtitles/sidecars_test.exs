defmodule Mydia.Subtitles.SidecarsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Subtitles.Sidecars

  describe "parse_filename/2" do
    test "a bare sidecar has an unknown language" do
      assert %{language: "und", forced: false, hearing_impaired: false} =
               Sidecars.parse_filename("Movie.srt", "Movie")
    end

    test "reads an ISO 639-1 code" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.en.srt", "Movie")
    end

    test "reads an ISO 639-2 code" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.eng.srt", "Movie")
    end

    test "reads an English language name" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.English.srt", "Movie")
    end

    test "is case insensitive" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.EN.srt", "Movie")
      assert %{language: "pt"} = Sidecars.parse_filename("Movie.Portuguese.srt", "Movie")
    end

    test "matches the media basename against the sidecar case-insensitively" do
      assert %{language: "en"} = Sidecars.parse_filename("MOVIE.EN.SRT", "Movie")
    end

    test "reads the forced flag" do
      assert %{language: "en", forced: true} =
               Sidecars.parse_filename("Movie.en.forced.srt", "Movie")
    end

    test "reads each hearing-impaired spelling" do
      for tag <- ~w(sdh cc) do
        assert %{language: "en", hearing_impaired: true} =
                 Sidecars.parse_filename("Movie.en.#{tag}.srt", "Movie")
      end
    end

    test "hi reads as Hindi, not as hearing impaired" do
      assert %{language: "hi", hearing_impaired: false} =
               Sidecars.parse_filename("Movie.hi.srt", "Movie")
    end

    test "a flag with no language still parses" do
      assert %{language: "und", forced: true} =
               Sidecars.parse_filename("Movie.forced.srt", "Movie")
    end

    test "ignores an unrecognized tag rather than treating it as a language" do
      assert %{language: "en"} = Sidecars.parse_filename("Movie.HDR.en.srt", "Movie")
    end

    test "handles a media basename containing dots" do
      assert %{language: "es"} =
               Sidecars.parse_filename(
                 "Some.Movie.2019.1080p.es.srt",
                 "Some.Movie.2019.1080p"
               )
    end

    test "a media basename that is a prefix of a longer basename does not swallow a tag" do
      assert %{language: "en"} =
               Sidecars.parse_filename("Movie.Sequel.en.srt", "Movie")
    end

    test "a sidecar that is exactly the basename plus extension has no tags" do
      assert %{language: "und", forced: false, hearing_impaired: false} =
               Sidecars.parse_filename("Some.Movie.2019.1080p.srt", "Some.Movie.2019.1080p")
    end
  end

  describe "reconcile/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "sidecars-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

      media_file =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mkv"
        })

      File.write!(Path.join(dir, "Movie.mkv"), "not really a video")

      %{dir: dir, media_file: Mydia.Repo.preload(media_file, :library_path)}
    end

    @srt """
    1
    00:00:01,000 --> 00:00:02,000
    Hello.
    """

    test "adopts a sidecar sitting beside the media file", %{dir: dir, media_file: media_file} do
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)

      assert {:ok, %{adopted: 1, reaped: 0}} = Sidecars.reconcile(media_file)

      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert subtitle.language == "en"
      assert subtitle.format == "srt"
      assert subtitle.origin == "sidecar"
    end

    test "ignores a subtitle belonging to a different media file", %{
      dir: dir,
      media_file: media_file
    } do
      File.write!(Path.join(dir, "OtherMovie.en.srt"), @srt)

      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(media_file)
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end

    test "leaves a row the Downloader already wrote", %{dir: dir, media_file: media_file} do
      path = Path.join(dir, "Movie.en.srt")
      File.write!(path, @srt)

      {:ok, existing} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "opensubtitles",
          subtitle_hash: "provider-hash",
          file_path: path,
          format: "srt",
          origin: "provider"
        })
        |> Mydia.Repo.insert()

      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(media_file)

      assert [unchanged] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert unchanged.id == existing.id
      assert unchanged.origin == "provider"
    end

    test "reaps a row whose file is gone", %{dir: dir, media_file: media_file} do
      {:ok, orphan} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "opensubtitles",
          subtitle_hash: "orphan-hash",
          file_path: Path.join(dir, "Movie.en.srt"),
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {:ok, _} = Mydia.Subtitles.TrackSettings.set_offset(media_file.id, orphan.id, 500)

      assert {:ok, %{reaped: 1}} = Sidecars.reconcile(media_file)
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, orphan.id) == 0
    end

    test "skips a file whose content is not a recognizable subtitle", %{
      dir: dir,
      media_file: media_file
    } do
      File.write!(Path.join(dir, "Movie.en.srt"), <<0, 1, 2, 3, 4>>)

      assert {:ok, %{adopted: 0, skipped: 1}} = Sidecars.reconcile(media_file)
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end

    test "skips a second sidecar with byte-identical content", %{
      dir: dir,
      media_file: media_file
    } do
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)
      File.write!(Path.join(dir, "Movie.eng.srt"), @srt)

      assert {:ok, %{adopted: 1, skipped: 1}} = Sidecars.reconcile(media_file)
      assert length(Mydia.Subtitles.list_subtitles(media_file.id)) == 1
    end

    test "an unreadable directory deletes nothing", %{dir: dir, media_file: media_file} do
      {:ok, existing} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "opensubtitles",
          subtitle_hash: "survivor-hash",
          file_path: Path.join(dir, "Movie.en.srt"),
          format: "srt"
        })
        |> Mydia.Repo.insert()

      File.rm_rf!(dir)

      assert {:error, _reason} = Sidecars.reconcile(media_file)

      assert [survivor] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert survivor.id == existing.id
    end

    test "reconciling a trashed media file does not reap its own live sidecar", %{
      dir: dir,
      media_file: media_file
    } do
      path = Path.join(dir, "Movie.en.srt")
      File.write!(path, @srt)

      {:ok, existing} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "opensubtitles",
          subtitle_hash: "trashed-hash",
          file_path: path,
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {:ok, trashed} =
        media_file
        |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Mydia.Repo.update()

      trashed = Mydia.Repo.preload(trashed, :library_path)

      # `Mydia.Library.list_media_files/1` excludes trashed rows by default,
      # so if the media file's own basename were sourced only from that
      # query, reconciling a trashed file would see no sibling matching its
      # own sidecar and would reap it, even with the file still on disk.
      assert {:ok, %{reaped: 0}} = Sidecars.reconcile(trashed)

      assert [survivor] = Mydia.Subtitles.list_subtitles(trashed.id)
      assert survivor.id == existing.id
    end
  end

  describe "reconcile_all/1" do
    test "returns a combined tally and does not raise on a missing directory" do
      media_file =
        Mydia.MediaFixtures.media_file_fixture()
        |> Mydia.Repo.preload(:library_path)

      assert %{adopted: 0, reaped: 0, errors: errors} = Sidecars.reconcile_all([media_file])
      assert is_list(errors)
    end
  end

  # Required deviation from the task brief: a bare `String.starts_with?` match
  # against one basename is wrong. Multi-version folders are common in
  # self-hosted libraries (`Movie.mkv` beside `Movie.Extended.mkv`), and
  # `Movie.Extended.en.srt` starts with BOTH basenames. Adopting it onto both
  # rows points two subtitle rows at one file; deleting either row through
  # `Mydia.Subtitles.delete_subtitle/1` then `File.rm/1`s a file that still
  # legitimately belongs to the other media file. The ruling: longest
  # matching basename in the directory wins, the way Plex and Jellyfin
  # disambiguate this.
  describe "reconcile/1 and reconcile_all/1 with multiple versions in one directory" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "sidecars-multi-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

      movie =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mkv"
        })
        |> Mydia.Repo.preload(:library_path)

      extended =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.Extended.mkv"
        })
        |> Mydia.Repo.preload(:library_path)

      File.write!(Path.join(dir, "Movie.mkv"), "not really a video")
      File.write!(Path.join(dir, "Movie.Extended.mkv"), "not really a video either")

      %{dir: dir, movie: movie, extended: extended}
    end

    test "a sidecar matching two basenames is adopted by the longer one only", %{
      dir: dir,
      movie: movie,
      extended: extended
    } do
      File.write!(Path.join(dir, "Movie.Extended.en.srt"), @srt)

      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(movie)
      assert Mydia.Subtitles.list_subtitles(movie.id) == []

      assert {:ok, %{adopted: 1}} = Sidecars.reconcile(extended)
      assert [subtitle] = Mydia.Subtitles.list_subtitles(extended.id)
      assert subtitle.file_path == Path.join(dir, "Movie.Extended.en.srt")
    end

    test "each media file adopts only its own sidecar via reconcile_all/1", %{
      dir: dir,
      movie: movie,
      extended: extended
    } do
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)
      File.write!(Path.join(dir, "Movie.Extended.en.srt"), @srt)

      assert %{adopted: 2} = Sidecars.reconcile_all([movie, extended])

      assert [movie_sub] = Mydia.Subtitles.list_subtitles(movie.id)
      assert movie_sub.file_path == Path.join(dir, "Movie.en.srt")

      assert [extended_sub] = Mydia.Subtitles.list_subtitles(extended.id)
      assert extended_sub.file_path == Path.join(dir, "Movie.Extended.en.srt")
    end

    test "reconcile/1 agrees with reconcile_all/1 even when the sibling is not in the argument list",
         %{dir: dir, movie: movie, extended: extended} do
      File.write!(Path.join(dir, "Movie.Extended.en.srt"), @srt)

      # `extended` is never passed to `reconcile/1` here, only `movie` is. If
      # sibling discovery were scoped to the argument list instead of the
      # database, this would wrongly adopt the extended sidecar onto `movie`
      # since the only known basename would be "Movie".
      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(movie)
      assert Mydia.Subtitles.list_subtitles(movie.id) == []

      assert %{adopted: 1} = Sidecars.reconcile_all([movie, extended])
      assert Mydia.Subtitles.list_subtitles(movie.id) == []

      assert [extended_sub] = Mydia.Subtitles.list_subtitles(extended.id)
      assert extended_sub.file_path == Path.join(dir, "Movie.Extended.en.srt")
    end

    test "a trashed sibling still claims its own sidecar so an active neighbour cannot adopt it",
         %{dir: dir, movie: movie, extended: extended} do
      File.write!(Path.join(dir, "Movie.Extended.en.srt"), @srt)

      # Trashing a media file moves the video out of the library path but
      # nothing moves its sidecar, so the file stays right where it was.
      # `extended`'s row still exists (trashed, not deleted), and its
      # basename must still win the longest match against `movie` even
      # though `extended` itself is not being reconciled here.
      {:ok, extended} =
        extended
        |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Mydia.Repo.update()

      extended = Mydia.Repo.preload(extended, :library_path)

      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(movie)
      assert Mydia.Subtitles.list_subtitles(movie.id) == []

      assert %{adopted: 0} = Sidecars.reconcile_all([movie])
      assert Mydia.Subtitles.list_subtitles(movie.id) == []

      # The sidecar is not adopted onto the trashed file either, since
      # nothing reconciles it while it is trashed. It simply stays
      # unclaimed, which is the safe outcome.
      assert Mydia.Subtitles.list_subtitles(extended.id) == []
    end
  end

  # Required deviation, part two: two sibling media files can reduce to the
  # exact same basename when only their container differs (`Movie.mkv`
  # beside `Movie.mp4`). Name matching cannot break that tie at all, so the
  # ruling is that exactly one file, the one `Mydia.Library.FileRanking.best/1`
  # would pick as the primary file, adopts the shared sidecar; the other
  # adopts nothing.
  describe "reconcile/1 and reconcile_all/1 with identical basenames" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "sidecars-identical-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

      low =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mp4",
          resolution: "480p"
        })
        |> Mydia.Repo.preload(:library_path)

      high =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mkv",
          resolution: "1080p"
        })
        |> Mydia.Repo.preload(:library_path)

      File.write!(Path.join(dir, "Movie.mp4"), "not really a video")
      File.write!(Path.join(dir, "Movie.mkv"), "not really a video either")

      %{dir: dir, low: low, high: high}
    end

    test "a sidecar shared by two identical basenames is adopted by the best-ranked file only",
         %{dir: dir, low: low, high: high} do
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)

      assert %{adopted: 1} = Sidecars.reconcile_all([low, high])

      assert Mydia.Subtitles.list_subtitles(low.id) == []
      assert [subtitle] = Mydia.Subtitles.list_subtitles(high.id)
      assert subtitle.file_path == Path.join(dir, "Movie.en.srt")
    end

    test "reconcile/1 agrees with reconcile_all/1 on which identical-basename file wins", %{
      dir: dir,
      low: low,
      high: high
    } do
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)

      assert {:ok, %{adopted: 0}} = Sidecars.reconcile(low)
      assert {:ok, %{adopted: 1}} = Sidecars.reconcile(high)

      assert Mydia.Subtitles.list_subtitles(low.id) == []
      assert [subtitle] = Mydia.Subtitles.list_subtitles(high.id)
      assert subtitle.file_path == Path.join(dir, "Movie.en.srt")
    end
  end
end
