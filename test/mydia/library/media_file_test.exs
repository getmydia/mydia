defmodule Mydia.Library.MediaFileTest do
  use Mydia.DataCase
  import ExUnit.CaptureLog

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath

  describe "absolute_path/1" do
    test "resolves absolute path from relative_path and library_path" do
      library_path = %LibraryPath{path: "/media/movies"}

      media_file = %MediaFile{
        relative_path: "The Matrix (1999)/The Matrix (1999) [1080p].mkv",
        library_path: library_path
      }

      assert MediaFile.absolute_path(media_file) ==
               "/media/movies/The Matrix (1999)/The Matrix (1999) [1080p].mkv"
    end

    test "returns nil when library_path is nil" do
      media_file = %MediaFile{
        relative_path: "Movie.mkv",
        library_path: nil
      }

      assert MediaFile.absolute_path(media_file) == nil
    end

    test "returns nil and warns when library_path is not loaded" do
      media_file = %MediaFile{
        id: "11111111-1111-1111-1111-111111111111",
        relative_path: "Movie.mkv",
        library_path: %Ecto.Association.NotLoaded{
          __field__: :library_path,
          __owner__: MediaFile,
          __cardinality__: :one
        }
      }

      log =
        capture_log(fn ->
          assert MediaFile.absolute_path(media_file) == nil
        end)

      assert log =~ "unloaded library_path"
    end

    test "returns nil when relative_path is nil" do
      library_path = %LibraryPath{path: "/media/movies"}

      media_file = %MediaFile{
        relative_path: nil,
        library_path: library_path
      }

      assert MediaFile.absolute_path(media_file) == nil
    end

    test "handles paths with special characters" do
      library_path = %LibraryPath{path: "/media/series"}

      media_file = %MediaFile{
        relative_path: "It's Always Sunny (2005)/Season 01/S01E01 - Charlie's Mom.mkv",
        library_path: library_path
      }

      assert MediaFile.absolute_path(media_file) ==
               "/media/series/It's Always Sunny (2005)/Season 01/S01E01 - Charlie's Mom.mkv"
    end
  end

  describe "library type compatibility validation" do
    setup do
      # Create library paths with different types (using unique paths to avoid conflicts)
      {:ok, movies_library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/movies",
          type: :movies,
          monitored: true
        })
        |> Repo.insert()

      {:ok, series_library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/series",
          type: :series,
          monitored: true
        })
        |> Repo.insert()

      {:ok, mixed_library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/mixed",
          type: :mixed,
          monitored: true
        })
        |> Repo.insert()

      %{
        movies_library: movies_library,
        series_library: series_library,
        mixed_library: mixed_library
      }
    end

    test "allows movies in :movies library", %{movies_library: movies_library} do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "The Matrix (1999)/The Matrix (1999) [1080p].mkv",
          library_path_id: movies_library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      assert changeset.valid?
    end

    test "prevents movies in :series library", %{series_library: series_library} do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "The Matrix (1999)/The Matrix (1999) [1080p].mkv",
          library_path_id: series_library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      refute changeset.valid?
      errors = errors_on(changeset).media_item_id
      assert length(errors) == 1
      assert hd(errors) =~ "cannot add movies to a library path configured for TV series only"
    end

    test "allows TV episodes in :series library", %{series_library: series_library} do
      tv_show = insert(:tv_show)
      episode = insert(:episode, media_item: tv_show)

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Breaking Bad/Season 01/S01E01.mkv",
          library_path_id: series_library.id,
          episode_id: episode.id,
          size: 1_000_000_000
        })

      assert changeset.valid?
    end

    test "prevents TV episodes in :movies library", %{movies_library: movies_library} do
      tv_show = insert(:tv_show)
      episode = insert(:episode, media_item: tv_show)

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Breaking Bad/Season 01/S01E01.mkv",
          library_path_id: movies_library.id,
          episode_id: episode.id,
          size: 1_000_000_000
        })

      refute changeset.valid?
      errors = errors_on(changeset).episode_id
      assert length(errors) == 1
      assert hd(errors) =~ "cannot add TV episodes to a library path configured for movies only"
    end

    test "allows both movies and TV shows in :mixed library", %{mixed_library: mixed_library} do
      movie = insert(:media_item, type: "movie")

      movie_changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "movies/The Matrix (1999).mkv",
          library_path_id: mixed_library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      assert movie_changeset.valid?

      tv_show = insert(:tv_show)
      episode = insert(:episode, media_item: tv_show)

      episode_changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "tv/Breaking Bad/S01E01.mkv",
          library_path_id: mixed_library.id,
          episode_id: episode.id,
          size: 1_000_000_000
        })

      assert episode_changeset.valid?
    end

    test "requires library_path_id when using new format" do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "movie.mkv",
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      refute changeset.valid?
      assert :library_path_id in Keyword.keys(changeset.errors)
    end

    test "allows orphaned files (no parent association)" do
      {:ok, library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/orphaned",
          type: :mixed,
          monitored: true
        })
        |> Repo.insert()

      changeset =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{
          relative_path: "orphaned.mkv",
          library_path_id: library.id,
          size: 1_000_000_000
        })

      assert changeset.valid?
    end

    test "validates with scan_changeset when parent is set", %{series_library: series_library} do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{
          relative_path: "movie.mkv",
          library_path_id: series_library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      refute changeset.valid?
      errors = errors_on(changeset).media_item_id
      assert length(errors) == 1
      assert hd(errors) =~ "cannot add movies to a library path configured for TV series only"
    end

    test "handles TV show type correctly in :movies library", %{movies_library: movies_library} do
      # Create a TV show media item
      tv_show = insert(:tv_show)

      # Try to add the TV show media item directly (not an episode) to movies library
      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Breaking Bad/series.mkv",
          library_path_id: movies_library.id,
          media_item_id: tv_show.id,
          size: 1_000_000_000
        })

      # This should be allowed because media_item_id can point to TV shows
      # The validation only prevents episodes in :movies libraries
      assert changeset.valid?
    end

    test "validates library_path_id exists via foreign key", %{series_library: series_library} do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "movie.mkv",
          library_path_id: series_library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      # Should be valid but type mismatch should fail
      refute changeset.valid?
    end
  end

  describe "validation edge cases" do
    test "handles nil relative_path gracefully" do
      {:ok, library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/validation",
          type: :movies,
          monitored: true
        })
        |> Repo.insert()

      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          library_path_id: library.id,
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      # Should fail on validate_required, not on library type validation
      refute changeset.valid?
      assert :relative_path in Keyword.keys(changeset.errors)
    end

    test "handles missing library_path_id gracefully" do
      movie = insert(:media_item, type: "movie")

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "movie.mkv",
          media_item_id: movie.id,
          size: 1_000_000_000
        })

      # Should fail on validate_required
      refute changeset.valid?
      assert :library_path_id in Keyword.keys(changeset.errors)
    end

    test "handles missing media_item gracefully" do
      {:ok, library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/validation2",
          type: :movies,
          monitored: true
        })
        |> Repo.insert()

      changeset =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "movie.mkv",
          library_path_id: library.id,
          media_item_id: Ecto.UUID.generate(),
          size: 1_000_000_000
        })

      # Should be valid from schema validation perspective
      # Foreign key constraint will catch the missing media_item on insert
      assert changeset.valid?
    end
  end

  describe "analysis state fields" do
    setup do
      {:ok, library} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: "/test/analysis-state",
          type: :movies,
          monitored: true
        })
        |> Repo.insert()

      %{library: library}
    end

    test "freshly inserted scan row defaults to analyzed_at nil and analysis_attempts 0", %{
      library: library
    } do
      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{
          relative_path: "Movie.mkv",
          library_path_id: library.id,
          size: 1_000_000_000
        })
        |> Repo.insert()

      reloaded = Repo.get!(MediaFile, media_file.id)

      assert is_nil(reloaded.analyzed_at)
      assert reloaded.analysis_attempts == 0
      assert is_nil(reloaded.last_analysis_error)
    end

    test "changeset/2 casts analyzed_at, analysis_attempts, and last_analysis_error", %{
      library: library
    } do
      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{
          relative_path: "Movie.mkv",
          library_path_id: library.id
        })
        |> Repo.insert()

      analyzed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, updated} =
        media_file
        |> MediaFile.scan_changeset(%{
          analyzed_at: analyzed_at,
          analysis_attempts: 2,
          last_analysis_error: ":ffprobe_timeout"
        })
        |> Repo.update()

      assert updated.analyzed_at == analyzed_at
      assert updated.analysis_attempts == 2
      assert updated.last_analysis_error == ":ffprobe_timeout"
    end

    test "scan_changeset/2 also casts the new fields", %{library: library} do
      analyzed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.scan_changeset(%{
          relative_path: "Other.mkv",
          library_path_id: library.id,
          analyzed_at: analyzed_at,
          analysis_attempts: 1,
          last_analysis_error: ":invalid_json"
        })
        |> Repo.insert()

      reloaded = Repo.get!(MediaFile, media_file.id)

      assert reloaded.analyzed_at == analyzed_at
      assert reloaded.analysis_attempts == 1
      assert reloaded.last_analysis_error == ":invalid_json"
    end
  end
end
