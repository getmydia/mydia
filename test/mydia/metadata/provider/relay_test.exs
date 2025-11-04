defmodule Mydia.Metadata.Provider.RelayTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay
  alias Mydia.Metadata.Provider.Error

  @moduletag :external

  @config %{
    type: :metadata_relay,
    base_url: "https://metadata-relay.dorninger.co/tmdb",
    options: %{
      language: "en-US",
      include_adult: false
    }
  }

  describe "test_connection/1" do
    test "successfully connects to relay service" do
      assert {:ok, result} = Relay.test_connection(@config)
      assert result.status == "ok"
      assert result.provider == "metadata_relay"
    end

    test "returns error for invalid base URL" do
      invalid_config = %{@config | base_url: "https://invalid-relay-service.example.com"}

      assert {:error, %Error{type: type}} = Relay.test_connection(invalid_config)
      assert type in [:connection_failed, :network_error]
    end
  end

  describe "search/3" do
    test "searches for movies by title" do
      assert {:ok, results} = Relay.search(@config, "The Matrix", media_type: :movie)

      assert is_list(results)
      assert length(results) > 0

      first_result = List.first(results)
      assert first_result.provider == :metadata_relay
      assert first_result.media_type == :movie
      assert String.contains?(String.downcase(first_result.title), "matrix")
      assert is_binary(first_result.provider_id)
    end

    test "searches for TV shows" do
      assert {:ok, results} = Relay.search(@config, "Breaking Bad", media_type: :tv_show)

      assert is_list(results)
      assert length(results) > 0

      first_result = List.first(results)
      assert first_result.provider == :metadata_relay
      assert first_result.media_type == :tv_show
      assert String.contains?(String.downcase(first_result.title), "breaking")
    end

    test "searches with year filter for movies" do
      assert {:ok, results} = Relay.search(@config, "The Matrix", media_type: :movie, year: 1999)

      assert is_list(results)
      assert length(results) > 0

      # The first result should be The Matrix from 1999
      first_result = List.first(results)
      assert first_result.year == 1999
      assert String.contains?(String.downcase(first_result.title), "matrix")
    end

    test "returns normalized search result structure" do
      assert {:ok, [result | _]} = Relay.search(@config, "The Matrix", media_type: :movie)

      assert is_binary(result.provider_id)
      assert result.provider == :metadata_relay
      assert is_binary(result.title)
      assert result.media_type in [:movie, :tv_show]

      # Optional fields can be nil
      assert is_binary(result.overview) or is_nil(result.overview)
      assert is_binary(result.poster_path) or is_nil(result.poster_path)
      assert is_binary(result.backdrop_path) or is_nil(result.backdrop_path)
      assert is_integer(result.year) or is_nil(result.year)
      assert is_float(result.vote_average) or is_nil(result.vote_average)
    end

    test "returns empty list for no matches" do
      assert {:ok, results} =
               Relay.search(@config, "ThisMovieTitleDefinitelyDoesNotExist12345")

      assert is_list(results)
      assert results == []
    end

    test "returns error for empty query" do
      assert {:error, %Error{type: :invalid_request}} = Relay.search(@config, "")
    end

    test "returns error for nil query" do
      assert {:error, %Error{type: :invalid_request}} = Relay.search(@config, nil)
    end
  end

  describe "fetch_by_id/3" do
    test "fetches movie metadata by ID" do
      # The Matrix (1999) - TMDB ID: 603
      assert {:ok, metadata} = Relay.fetch_by_id(@config, "603", media_type: :movie)

      assert metadata.provider_id == "603"
      assert metadata.provider == :metadata_relay
      assert metadata.media_type == :movie
      assert metadata.title == "The Matrix"
      assert metadata.year == 1999
      assert is_binary(metadata.overview)
      assert is_integer(metadata.runtime)
      assert metadata.runtime > 0
      assert is_list(metadata.genres)
      assert length(metadata.genres) > 0
      assert is_binary(metadata.imdb_id)
    end

    test "fetches TV show metadata by ID" do
      # Breaking Bad - TMDB ID: 1396
      assert {:ok, metadata} = Relay.fetch_by_id(@config, "1396", media_type: :tv_show)

      assert metadata.provider_id == "1396"
      assert metadata.provider == :metadata_relay
      assert metadata.media_type == :tv_show
      assert metadata.title == "Breaking Bad"
      assert is_binary(metadata.overview)
      assert is_integer(metadata.number_of_seasons)
      assert is_integer(metadata.number_of_episodes)
      assert metadata.number_of_seasons > 0
      assert metadata.number_of_episodes > 0
    end

    test "includes cast and crew when credits are appended" do
      assert {:ok, metadata} =
               Relay.fetch_by_id(@config, "603",
                 media_type: :movie,
                 append_to_response: ["credits"]
               )

      assert is_list(metadata.cast)
      assert is_list(metadata.crew)
      assert length(metadata.cast) > 0
      assert length(metadata.crew) > 0

      # Check cast member structure
      cast_member = List.first(metadata.cast)
      assert is_binary(cast_member.name)
      assert is_binary(cast_member.character)
      assert is_integer(cast_member.order)

      # Check crew member structure
      crew_member = List.first(metadata.crew)
      assert is_binary(crew_member.name)
      assert is_binary(crew_member.job)
      assert is_binary(crew_member.department)
    end

    test "returns error for non-existent ID" do
      assert {:error, %Error{type: :not_found}} =
               Relay.fetch_by_id(@config, "99999999", media_type: :movie)
    end

    test "normalizes metadata structure correctly" do
      assert {:ok, metadata} = Relay.fetch_by_id(@config, "603", media_type: :movie)

      # Required fields
      assert is_binary(metadata.provider_id)
      assert metadata.provider == :metadata_relay
      assert metadata.media_type in [:movie, :tv_show]
      assert is_binary(metadata.title)

      # Optional fields
      assert is_binary(metadata.original_title) or is_nil(metadata.original_title)
      assert is_integer(metadata.year) or is_nil(metadata.year)
      assert is_struct(metadata.release_date, Date) or is_nil(metadata.release_date)
      assert is_binary(metadata.overview) or is_nil(metadata.overview)
      assert is_binary(metadata.tagline) or is_nil(metadata.tagline)
      assert is_integer(metadata.runtime) or is_nil(metadata.runtime)
      assert is_binary(metadata.status) or is_nil(metadata.status)
      assert is_list(metadata.genres)
      assert is_list(metadata.production_companies)
      assert is_list(metadata.production_countries)
      assert is_list(metadata.spoken_languages)
      assert is_list(metadata.cast)
      assert is_list(metadata.crew)
    end
  end

  describe "fetch_images/3" do
    test "fetches movie images" do
      assert {:ok, images} = Relay.fetch_images(@config, "603", media_type: :movie)

      assert is_map(images)
      assert is_list(images.posters)
      assert is_list(images.backdrops)
      assert is_list(images.logos)

      # Should have at least some posters
      assert length(images.posters) > 0

      # Check poster structure
      poster = List.first(images.posters)
      assert is_binary(poster.file_path)
      assert is_integer(poster.width)
      assert is_integer(poster.height)
      assert is_float(poster.aspect_ratio)
    end

    test "fetches TV show images" do
      assert {:ok, images} = Relay.fetch_images(@config, "1396", media_type: :tv_show)

      assert is_map(images)
      assert is_list(images.posters)
      assert is_list(images.backdrops)
      assert length(images.posters) > 0
    end

    test "returns error for non-existent ID" do
      assert {:error, %Error{type: :not_found}} =
               Relay.fetch_images(@config, "99999999", media_type: :movie)
    end

    test "normalizes image structure correctly" do
      assert {:ok, images} = Relay.fetch_images(@config, "603", media_type: :movie)

      poster = List.first(images.posters)

      assert is_binary(poster.file_path)
      assert is_integer(poster.width)
      assert is_integer(poster.height)
      assert is_float(poster.aspect_ratio)
      assert is_float(poster.vote_average) or is_nil(poster.vote_average)
      assert is_integer(poster.vote_count) or is_nil(poster.vote_count)
    end
  end

  describe "fetch_season/4" do
    test "fetches TV show season with episodes" do
      # Breaking Bad Season 1
      assert {:ok, season} = Relay.fetch_season(@config, "1396", 1)

      assert season.season_number == 1
      assert is_binary(season.name)
      assert is_binary(season.overview) or is_nil(season.overview)
      assert is_struct(season.air_date, Date) or is_nil(season.air_date)
      assert is_binary(season.poster_path) or is_nil(season.poster_path)
      assert is_integer(season.episode_count)
      assert season.episode_count > 0

      # Check episodes
      assert is_list(season.episodes)
      assert length(season.episodes) == season.episode_count

      # Check first episode structure
      episode = List.first(season.episodes)
      assert episode.episode_number == 1
      assert is_binary(episode.name)
      assert is_binary(episode.overview) or is_nil(episode.overview)
      assert is_struct(episode.air_date, Date) or is_nil(episode.air_date)
    end

    test "returns error for non-existent season" do
      assert {:error, %Error{type: :not_found}} =
               Relay.fetch_season(@config, "1396", 999)
    end

    test "returns error for non-existent TV show" do
      assert {:error, %Error{type: :not_found}} =
               Relay.fetch_season(@config, "99999999", 1)
    end

    test "normalizes episode structure correctly" do
      assert {:ok, season} = Relay.fetch_season(@config, "1396", 1)

      episode = List.first(season.episodes)

      assert is_integer(episode.episode_number)
      assert is_binary(episode.name)
      assert is_binary(episode.overview) or is_nil(episode.overview)
      assert is_struct(episode.air_date, Date) or is_nil(episode.air_date)
      assert is_integer(episode.runtime) or is_nil(episode.runtime)
      assert is_binary(episode.still_path) or is_nil(episode.still_path)
      assert is_float(episode.vote_average) or is_nil(episode.vote_average)
      assert is_integer(episode.vote_count) or is_nil(episode.vote_count)
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      config = %{@config | base_url: "https://localhost:99999"}

      assert {:error, %Error{}} = Relay.search(config, "The Matrix")
    end

    test "handles invalid configuration" do
      config = %{@config | base_url: "not-a-valid-url"}

      assert {:error, %Error{}} = Relay.search(config, "The Matrix")
    end
  end

  describe "multi-language support" do
    test "searches with custom language" do
      assert {:ok, results} =
               Relay.search(@config, "The Matrix", media_type: :movie, language: "es-ES")

      assert is_list(results)
      assert length(results) > 0
    end

    test "fetches metadata with custom language" do
      assert {:ok, metadata} =
               Relay.fetch_by_id(@config, "603", media_type: :movie, language: "es-ES")

      assert is_binary(metadata.title)
      assert is_binary(metadata.overview)
    end
  end

  describe "pagination" do
    test "searches with pagination" do
      assert {:ok, page1} = Relay.search(@config, "matrix", media_type: :movie, page: 1)
      assert {:ok, page2} = Relay.search(@config, "matrix", media_type: :movie, page: 2)

      assert is_list(page1)
      assert is_list(page2)
      assert length(page1) > 0

      # Pages should have different results (unless there's only one page of results)
      # We just verify both queries succeed
    end
  end
end
