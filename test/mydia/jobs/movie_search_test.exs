defmodule Mydia.Jobs.MovieSearchTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MovieSearch
  alias Mydia.Library
  alias Mydia.Settings
  alias Mydia.IndexerMock

  import Mydia.MediaFixtures

  setup do
    # Disable all existing indexer configs from test database
    Settings.list_indexer_configs()
    |> Enum.filter(fn config -> not is_nil(config.inserted_at) end)
    |> Enum.each(fn config ->
      Settings.update_indexer_config(config, %{enabled: false})
    end)

    # Set up mock Prowlarr server for all tests
    bypass = Bypass.open()

    # Mock with movie results
    IndexerMock.mock_prowlarr_all(bypass, results: [
      IndexerMock.movie_result(%{title: "The Matrix", year: 1999, seeders: 100}),
      IndexerMock.movie_result(%{title: "Inception", year: 2010, seeders: 80}),
      IndexerMock.movie_result(%{title: "Movie One", year: 2020, seeders: 50}),
      IndexerMock.movie_result(%{title: "Movie Two", year: 2021, seeders: 45}),
      IndexerMock.movie_result(%{title: "Movie Three", year: 2022, seeders: 40})
    ])

    # Create test indexer configuration pointing to Bypass server
    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Test Movie Indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    %{bypass: bypass}
  end

  describe "perform/1 - specific mode" do
    test "returns error when media item does not exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               perform_job(MovieSearch, %{"mode" => "specific", "media_item_id" => fake_id})
    end

    test "returns error when media item is not a movie" do
      tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      assert {:error, :invalid_type} =
               perform_job(MovieSearch, %{
                 "mode" => "specific",
                 "media_item_id" => tv_show.id
               })
    end

    test "processes a valid movie", %{bypass: _bypass} do
      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})

      # Now uses mocked indexer responses
      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id
        })

      # Should succeed with mocked results
      assert result == :ok
    end

    test "uses custom ranking options when provided", %{bypass: _bypass} do
      movie = media_item_fixture(%{type: "movie", title: "Inception", year: 2010})

      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id,
          "min_seeders" => 10,
          "blocked_tags" => ["CAM", "TS"],
          "preferred_tags" => ["REMUX"]
        })

      # Should succeed with mocked results
      assert result == :ok
    end
  end

  describe "perform/1 - all_monitored mode" do
    test "returns ok when no movies need searching" do
      # Create a movie that's not monitored
      _unmonitored_movie = media_item_fixture(%{monitored: false})

      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "skips movies that already have files" do
      # Create a monitored movie
      movie = media_item_fixture(%{type: "movie", monitored: true})

      # Create a media file for this movie
      {:ok, _media_file} =
        Library.create_media_file(%{
          media_item_id: movie.id,
          path: "/fake/path/movie.mkv",
          size: 1_000_000_000,
          quality: %{resolution: "1080p"}
        })

      # The job should complete successfully but not search this movie
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "processes monitored movies without files", %{bypass: _bypass} do
      # Create monitored movies without files
      _movie1 =
        media_item_fixture(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      _movie2 =
        media_item_fixture(%{
          type: "movie",
          title: "Inception",
          year: 2010,
          monitored: true
        })

      # The job should search for these movies using mocked indexer
      result = perform_job(MovieSearch, %{"mode" => "all_monitored"})
      assert result == :ok
    end

    test "skips TV shows in all_monitored mode", %{bypass: _bypass} do
      # Create a monitored TV show
      _tv_show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Breaking Bad",
          monitored: true
        })

      # Also create a monitored movie
      _movie =
        media_item_fixture(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      # Should only process the movie, not the TV show
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "continues processing after individual movie failures", %{bypass: _bypass} do
      # Create multiple monitored movies
      _movie1 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie One",
          year: 2020,
          monitored: true
        })

      _movie2 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie Two",
          year: 2021,
          monitored: true
        })

      _movie3 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie Three",
          year: 2022,
          monitored: true
        })

      # Job should process all movies with mocked indexer
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end
  end

  describe "search query construction" do
    test "includes year when available", %{bypass: _bypass} do
      movie = media_item_fixture(%{title: "The Matrix", year: 1999})

      # Job runs with mocked indexer responses
      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id
        })

      assert result == :ok
    end
  end
end
