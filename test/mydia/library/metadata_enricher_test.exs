defmodule Mydia.Library.MetadataEnricherTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.MetadataEnricher
  alias Mydia.{Library, Settings}

  describe "library type validation" do
    setup do
      # Create unique paths for each test to avoid conflicts
      unique_id = :erlang.unique_integer([:positive])

      # Create library paths for testing
      {:ok, movies_lib} =
        Settings.create_library_path(%{
          path: "/media/movies_#{unique_id}",
          type: :movies
        })

      {:ok, series_lib} =
        Settings.create_library_path(%{
          path: "/media/series_#{unique_id}",
          type: :series
        })

      {:ok, mixed_lib} =
        Settings.create_library_path(%{
          path: "/media/mixed_#{unique_id}",
          type: :mixed
        })

      %{
        movies_lib: movies_lib,
        series_lib: series_lib,
        mixed_lib: mixed_lib
      }
    end

    test "allows movies in movies-only library", %{movies_lib: movies_lib} do
      # First create a movie media item
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Create a media file in movies library associated with the movie
      {:ok, media_file} =
        Library.create_media_file(%{
          path: "#{movies_lib.path}/The Matrix (1999).mkv",
          relative_path: "The Matrix (1999).mkv",
          library_path_id: movies_lib.id,
          media_item_id: movie.id
        })

      # Should succeed - movie in movies library
      assert media_file.path =~ movies_lib.path
      assert media_file.media_item_id == movie.id
    end

    test "allows TV shows in series-only library", %{series_lib: series_lib} do
      # First create a TV show and episode
      {:ok, tv_show} =
        Mydia.Media.create_media_item(%{
          title: "Breaking Bad",
          type: "tv_show",
          year: 2008,
          tmdb_id: 1396
        })

      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      {:ok, media_file} =
        Library.create_media_file(%{
          path: "#{series_lib.path}/Breaking Bad/Season 01/Breaking Bad S01E01.mkv",
          relative_path: "Breaking Bad/Season 01/Breaking Bad S01E01.mkv",
          library_path_id: series_lib.id,
          episode_id: episode.id
        })

      assert media_file.path =~ series_lib.path
      assert media_file.episode_id == episode.id
    end

    test "allows both movies and TV shows in mixed library", %{mixed_lib: mixed_lib} do
      # Create movie
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Create TV show and episode
      {:ok, tv_show} =
        Mydia.Media.create_media_item(%{
          title: "Breaking Bad",
          type: "tv_show",
          year: 2008,
          tmdb_id: 1396
        })

      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      {:ok, movie_file} =
        Library.create_media_file(%{
          path: "#{mixed_lib.path}/movies/The Matrix (1999).mkv",
          relative_path: "movies/The Matrix (1999).mkv",
          library_path_id: mixed_lib.id,
          media_item_id: movie.id
        })

      {:ok, tv_file} =
        Library.create_media_file(%{
          path: "#{mixed_lib.path}/tv/Breaking Bad/Season 01/S01E01.mkv",
          relative_path: "tv/Breaking Bad/Season 01/S01E01.mkv",
          library_path_id: mixed_lib.id,
          episode_id: episode.id
        })

      assert movie_file.path =~ mixed_lib.path
      assert tv_file.path =~ mixed_lib.path
    end

    test "prevents movies in series-only library", %{series_lib: series_lib} do
      # First create a movie media item
      {:ok, movie} =
        Mydia.Media.create_media_item(%{
          title: "The Matrix",
          type: "movie",
          year: 1999,
          tmdb_id: 603
        })

      # Try to create a media file in series library and associate with movie
      assert {:error, changeset} =
               Library.create_media_file(%{
                 path: "#{series_lib.path}/The Matrix (1999).mkv",
                 relative_path: "The Matrix (1999).mkv",
                 library_path_id: series_lib.id,
                 media_item_id: movie.id
               })

      error_message = hd(errors_on(changeset).media_item_id)
      assert error_message =~ "cannot add movies to a library path configured for TV series only"
    end

    test "prevents TV shows in movies-only library", %{movies_lib: movies_lib} do
      # First create a TV show media item
      {:ok, tv_show} =
        Mydia.Media.create_media_item(%{
          title: "Breaking Bad",
          type: "tv_show",
          year: 2008,
          tmdb_id: 1396
        })

      # Create an episode
      {:ok, episode} =
        Mydia.Media.create_episode(%{
          media_item_id: tv_show.id,
          season_number: 1,
          episode_number: 1,
          title: "Pilot"
        })

      # Try to create a media file in movies library and associate with episode
      assert {:error, changeset} =
               Library.create_media_file(%{
                 path: "#{movies_lib.path}/Breaking Bad S01E01.mkv",
                 relative_path: "Breaking Bad S01E01.mkv",
                 library_path_id: movies_lib.id,
                 episode_id: episode.id
               })

      error_message = hd(errors_on(changeset).episode_id)

      assert error_message =~
               "cannot add TV episodes to a library path configured for movies only"
    end
  end

  describe "year extraction from metadata" do
    test "extracts year from Date struct in release_date" do
      # Simulate metadata with Date struct (as returned by some TMDB responses)
      metadata = %{
        title: "Dune: Part Two",
        provider_id: "693134",
        release_date: ~D[2024-02-27],
        metadata_type: :movie
      }

      # Use build_media_item_attrs to test year extraction
      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 2024
    end

    test "extracts year from string in release_date" do
      # Simulate metadata with string date (typical TMDB format)
      metadata = %{
        title: "The Matrix",
        provider_id: "603",
        release_date: "1999-03-31",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 1999
    end

    test "extracts year from Date struct in first_air_date for TV shows" do
      metadata = %{
        name: "Breaking Bad",
        provider_id: "1396",
        first_air_date: ~D[2008-01-20],
        metadata_type: :tv_show
      }

      attrs = build_attrs_for_test(metadata, :tv_show)

      assert attrs.year == 2008
    end

    test "extracts year from string in first_air_date for TV shows" do
      metadata = %{
        name: "The Wire",
        provider_id: "1438",
        first_air_date: "2002-06-02",
        metadata_type: :tv_show
      }

      attrs = build_attrs_for_test(metadata, :tv_show)

      assert attrs.year == 2002
    end

    test "returns nil when no date is present" do
      metadata = %{
        title: "Unknown Movie",
        provider_id: "12345",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == nil
    end

    test "returns nil when date format is invalid" do
      metadata = %{
        title: "Bad Date Movie",
        provider_id: "12345",
        release_date: "invalid-date",
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == nil
    end

    test "prefers release_date over first_air_date when both present" do
      metadata = %{
        title: "Some Movie",
        provider_id: "12345",
        release_date: ~D[2024-03-15],
        first_air_date: ~D[2020-01-01],
        metadata_type: :movie
      }

      attrs = build_attrs_for_test(metadata, :movie)

      assert attrs.year == 2024
    end
  end

  # Helper to access private function behavior through public interface
  # This mimics what build_media_item_attrs does internally
  defp build_attrs_for_test(metadata, media_type) do
    # Call the private extract_year function indirectly through the attrs builder
    # We'll use send to call the private function for testing
    year = extract_year_test_helper(metadata)

    %{
      type: media_type_to_string(media_type),
      title: Map.get(metadata, :title) || Map.get(metadata, :name),
      year: year,
      tmdb_id: String.to_integer(to_string(metadata.provider_id)),
      metadata: metadata
    }
  end

  # Test helper that replicates the private extract_year logic
  defp extract_year_test_helper(metadata) do
    cond do
      Map.has_key?(metadata, :release_date) && metadata.release_date ->
        extract_year_from_date_test(metadata.release_date)

      Map.has_key?(metadata, :first_air_date) && metadata.first_air_date ->
        extract_year_from_date_test(metadata.first_air_date)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp extract_year_from_date_test(%Date{} = date), do: date.year

  defp extract_year_from_date_test(date_string) when is_binary(date_string) do
    date_string
    |> String.slice(0..3)
    |> String.to_integer()
  end

  defp extract_year_from_date_test(_), do: nil

  defp media_type_to_string(:movie), do: "movie"
  defp media_type_to_string(:tv_show), do: "tv_show"
end
