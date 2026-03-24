defmodule Mydia.Library.FileOrganizerTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.FileOrganizer
  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Settings.LibraryPath

  # Helper to generate unique paths for each test
  defp unique_path(base), do: "#{base}/#{System.unique_integer([:positive])}"

  describe "destination_path/2" do
    test "returns path with category folder when auto_organize is enabled" do
      library_path = %LibraryPath{
        path: "/media/movies",
        auto_organize: true,
        category_paths: %{"anime_movie" => "Anime", "cartoon_movie" => "Cartoons"}
      }

      media_item = %MediaItem{
        title: "Spirited Away",
        year: 2001,
        type: "movie",
        category: "anime_movie"
      }

      assert FileOrganizer.destination_path(media_item, library_path) ==
               "/media/movies/Anime/Spirited Away (2001)"
    end

    test "returns path without category folder when auto_organize is disabled" do
      library_path = %LibraryPath{
        path: "/media/movies",
        auto_organize: false,
        category_paths: %{"anime_movie" => "Anime"}
      }

      media_item = %MediaItem{
        title: "Spirited Away",
        year: 2001,
        type: "movie",
        category: "anime_movie"
      }

      assert FileOrganizer.destination_path(media_item, library_path) ==
               "/media/movies/Spirited Away (2001)"
    end

    test "returns path without category folder when category not in category_paths" do
      library_path = %LibraryPath{
        path: "/media/movies",
        auto_organize: true,
        category_paths: %{"anime_movie" => "Anime"}
      }

      media_item = %MediaItem{
        title: "The Matrix",
        year: 1999,
        type: "movie",
        category: "movie"
      }

      assert FileOrganizer.destination_path(media_item, library_path) ==
               "/media/movies/The Matrix (1999)"
    end

    test "handles movie without year" do
      library_path = %LibraryPath{
        path: "/media/movies",
        auto_organize: false,
        category_paths: %{}
      }

      media_item = %MediaItem{
        title: "Unknown Movie",
        year: nil,
        type: "movie",
        category: "movie"
      }

      assert FileOrganizer.destination_path(media_item, library_path) ==
               "/media/movies/Unknown Movie"
    end

    test "handles TV show with category path" do
      library_path = %LibraryPath{
        path: "/media/tv",
        auto_organize: true,
        category_paths: %{"anime_series" => "Anime"}
      }

      media_item = %MediaItem{
        title: "Naruto",
        type: "tv_show",
        category: "anime_series"
      }

      assert FileOrganizer.destination_path(media_item, library_path) ==
               "/media/tv/Anime/Naruto"
    end

    test "sanitizes filenames with special characters" do
      library_path = %LibraryPath{
        path: "/media/movies",
        auto_organize: false,
        category_paths: %{}
      }

      media_item = %MediaItem{
        title: "What If...?",
        year: 2021,
        type: "movie",
        category: "movie"
      }

      result = FileOrganizer.destination_path(media_item, library_path)
      # The ? should be removed
      refute String.contains?(result, "?")
      assert result == "/media/movies/What If... (2021)"
    end
  end

  describe "organize_file/2 with dry_run" do
    setup do
      base_path = unique_path("/media/movies")

      # Create library path
      {:ok, library_path} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: base_path,
          type: :movies,
          auto_organize: true,
          category_paths: %{"anime_movie" => "Anime"}
        })
        |> Repo.insert()

      # Create media item
      {:ok, media_item} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          title: "Spirited Away",
          year: 2001,
          type: "movie"
        })
        |> Repo.insert()

      # Set category using category_changeset
      {:ok, media_item} =
        media_item
        |> MediaItem.category_changeset(:anime_movie)
        |> Repo.update()

      # Create media file
      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Spirited Away (2001)/movie.mkv",
          library_path_id: library_path.id,
          media_item_id: media_item.id
        })
        |> Repo.insert()

      %{
        library_path: library_path,
        media_item: media_item,
        media_file: media_file,
        base_path: base_path
      }
    end

    test "returns correct destination in dry_run mode", %{
      media_file: media_file,
      base_path: base_path
    } do
      {:ok, result} = FileOrganizer.organize_file(media_file, dry_run: true)

      assert result.source == "#{base_path}/Spirited Away (2001)/movie.mkv"
      assert result.destination == "#{base_path}/Anime/Spirited Away (2001)/movie.mkv"
      assert result.action == :move
      assert result.reason == nil
    end

    test "reports skip when file already in correct location", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create a media file that's already in the correct location
      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Anime/Spirited Away (2001)/movie.mkv",
          library_path_id: library_path.id,
          media_item_id: media_item.id
        })
        |> Repo.insert()

      {:ok, result} = FileOrganizer.organize_file(media_file, dry_run: true)

      assert result.action == :skip
      assert result.reason == "already in correct location"
    end
  end

  describe "preview_destination/1" do
    setup do
      base_path = unique_path("/media/tv")

      {:ok, library_path} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: base_path,
          type: :series,
          auto_organize: true,
          category_paths: %{"anime_series" => "Anime"}
        })
        |> Repo.insert()

      {:ok, media_item} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          title: "Naruto",
          type: "tv_show"
        })
        |> Repo.insert()

      # Set category using category_changeset
      {:ok, media_item} =
        media_item
        |> MediaItem.category_changeset(:anime_series)
        |> Repo.update()

      {:ok, media_file} =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Naruto/Season 01/episode.mkv",
          library_path_id: library_path.id,
          media_item_id: media_item.id
        })
        |> Repo.insert()

      %{media_file: media_file, base_path: base_path}
    end

    test "returns expected destination path", %{media_file: media_file, base_path: base_path} do
      {:ok, dest} = FileOrganizer.preview_destination(media_file)
      assert dest == "#{base_path}/Anime/Naruto/episode.mkv"
    end
  end

  describe "reorganize_library/2 with dry_run" do
    setup do
      base_path = unique_path("/media/movies")

      {:ok, library_path} =
        %LibraryPath{}
        |> LibraryPath.changeset(%{
          path: base_path,
          type: :movies,
          auto_organize: true,
          category_paths: %{"anime_movie" => "Anime", "cartoon_movie" => "Cartoons"}
        })
        |> Repo.insert()

      # Create anime movie
      {:ok, anime_item} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          title: "Spirited Away",
          year: 2001,
          type: "movie"
        })
        |> Repo.insert()

      # Set category using category_changeset
      {:ok, anime_item} =
        anime_item
        |> MediaItem.category_changeset(:anime_movie)
        |> Repo.update()

      {:ok, anime_file} =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "Spirited Away (2001)/movie.mkv",
          library_path_id: library_path.id,
          media_item_id: anime_item.id
        })
        |> Repo.insert()

      # Create regular movie (already in correct location)
      {:ok, movie_item} =
        %MediaItem{}
        |> MediaItem.changeset(%{
          title: "The Matrix",
          year: 1999,
          type: "movie"
        })
        |> Repo.insert()

      # Set category using category_changeset
      {:ok, movie_item} =
        movie_item
        |> MediaItem.category_changeset(:movie)
        |> Repo.update()

      {:ok, movie_file} =
        %MediaFile{}
        |> MediaFile.changeset(%{
          relative_path: "The Matrix (1999)/movie.mkv",
          library_path_id: library_path.id,
          media_item_id: movie_item.id
        })
        |> Repo.insert()

      %{
        library_path: library_path,
        anime_file: anime_file,
        movie_file: movie_file
      }
    end

    test "returns summary of reorganization", %{library_path: library_path} do
      {:ok, summary} = FileOrganizer.reorganize_library(library_path, dry_run: true)

      assert summary.total == 2
      # One file needs to move (anime), one is already correct (regular movie)
      assert summary.moved == 1
      assert summary.skipped == 1
      assert summary.errors == 0
      assert length(summary.details) == 2
    end
  end
end
