defmodule Mydia.Metadata.Provider.Relay do
  @moduledoc """
  Metadata provider adapter for metadata-relay service.

  This adapter interfaces with the self-hosted metadata-relay service
  (https://metadata-relay.fly.dev) which acts as a caching proxy for TMDB and TVDB APIs.
  Using the relay provides several benefits:

    * No API key required for basic usage
    * Built-in caching reduces redundant API calls
    * Rate limit protection from the relay's pooled quotas
    * Lower latency for frequently requested metadata

  ## Configuration

  The relay provider can be configured with custom relay endpoints or uses the default
  from `Mydia.Metadata.default_relay_config()`:

      config = %{
        type: :metadata_relay,
        base_url: "https://metadata-relay.fly.dev",
        options: %{
          language: "en-US",
          include_adult: false,
          timeout: 30_000
        }
      }

  ## Usage

      # Search for movies
      {:ok, results} = Relay.search(config, "The Matrix", media_type: :movie)

      # Fetch detailed metadata
      {:ok, metadata} = Relay.fetch_by_id(config, "603", media_type: :movie)

      # Fetch images
      {:ok, images} = Relay.fetch_images(config, "603", media_type: :movie)

      # Fetch TV season (for TV shows)
      {:ok, season} = Relay.fetch_season(config, "1396", 1)

  ## Relay Endpoints

  The relay provides endpoints for both TMDB and TVDB:
    * `/tmdb/movies/search` - Search movies via TMDB
    * `/tmdb/tv/search` - Search TV shows via TMDB
    * `/tmdb/movies/{id}` - Get movie details from TMDB
    * `/tmdb/tv/shows/{id}` - Get TV show details from TMDB
    * `/tmdb/movies/{id}/images` - Get movie images from TMDB
    * `/tmdb/tv/shows/{id}/images` - Get TV show images from TMDB
    * `/tmdb/tv/shows/{id}/{season_number}` - Get TV season details from TMDB

  ## Image URLs

  The relay returns relative image paths (e.g., "/poster.jpg") which need to be
  prefixed with the TMDB image base URL. For TMDB images, use:

      https://image.tmdb.org/t/p/w500/poster.jpg (500px width)
      https://image.tmdb.org/t/p/original/poster.jpg (original size)

  Available sizes: w92, w154, w185, w342, w500, w780, original
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.{Error, HTTP}

  alias Mydia.Metadata.Structs.{
    SearchResult,
    MediaMetadata,
    SeasonData,
    EpisodeData,
    ImageData,
    ImagesResponse
  }

  @default_language "en-US"

  @impl true
  def test_connection(config) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/configuration") do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, %{status: "ok", provider: "metadata_relay"}}

      {:ok, %{status: status}} ->
        {:error, Error.connection_failed("Relay returned status #{status}")}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    when_valid_query(query, fn ->
      media_type = Keyword.get(opts, :media_type)
      year = Keyword.get(opts, :year)
      language = Keyword.get(opts, :language, @default_language)
      include_adult = Keyword.get(opts, :include_adult, false)
      page = Keyword.get(opts, :page, 1)

      endpoint = search_endpoint(media_type)

      params =
        [
          query: query,
          language: language,
          include_adult: include_adult,
          page: page
        ]
        |> maybe_add_year(year, media_type)

      req = HTTP.new_request(config)

      case HTTP.get(req, endpoint, params: params) do
        {:ok, %{status: 200, body: body}} ->
          results = parse_search_results(body)
          {:ok, results}

        {:ok, %{status: status, body: body}} ->
          {:error, Error.api_error("Search failed with status #{status}", %{body: body})}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @impl true
  def fetch_by_id(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    language = Keyword.get(opts, :language, @default_language)
    append = Keyword.get(opts, :append_to_response, ["credits", "alternative_titles"])

    endpoint = build_details_endpoint(media_type, provider_id)

    params = [
      language: language,
      append_to_response: Enum.join(append, ",")
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        metadata = parse_metadata(body, media_type, provider_id)
        {:ok, metadata}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Media not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_images(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    language = Keyword.get(opts, :language)
    include_image_language = Keyword.get(opts, :include_image_language)

    endpoint = build_images_endpoint(media_type, provider_id)

    params =
      []
      |> maybe_add_param(:language, language)
      |> maybe_add_param(:include_image_language, include_image_language)

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        images = parse_images(body)
        {:ok, images}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Media not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch images failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_season(config, provider_id, season_number, opts \\ []) do
    language = Keyword.get(opts, :language, @default_language)

    endpoint = "/tmdb/tv/shows/#{provider_id}/#{season_number}"
    params = [language: language]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        season = parse_season(body)
        {:ok, season}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Season not found: #{provider_id}/#{season_number}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch season failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_trending(config, opts \\ []) do
    media_type = Keyword.get(opts, :media_type)
    language = Keyword.get(opts, :language, @default_language)
    page = Keyword.get(opts, :page, 1)

    endpoint = build_trending_endpoint(media_type)

    params = [
      language: language,
      page: page
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch trending failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  ## Private Functions

  defp when_valid_query(query, callback) when is_binary(query) and byte_size(query) > 0 do
    callback.()
  end

  defp when_valid_query(_query, _callback) do
    {:error, Error.invalid_request("Query must be a non-empty string")}
  end

  defp search_endpoint(nil), do: "/tmdb/movies/search"
  defp search_endpoint(:movie), do: "/tmdb/movies/search"
  defp search_endpoint(:tv_show), do: "/tmdb/tv/search"

  defp build_details_endpoint(:movie, id), do: "/tmdb/movies/#{id}"
  defp build_details_endpoint(:tv_show, id), do: "/tmdb/tv/shows/#{id}"

  defp build_images_endpoint(:movie, id), do: "/tmdb/movies/#{id}/images"
  defp build_images_endpoint(:tv_show, id), do: "/tmdb/tv/shows/#{id}/images"

  defp build_trending_endpoint(:movie), do: "/tmdb/movies/trending"
  defp build_trending_endpoint(:tv_show), do: "/tmdb/tv/trending"
  defp build_trending_endpoint(_), do: "/tmdb/movies/trending"

  defp maybe_add_year(params, nil, _media_type), do: params
  defp maybe_add_year(params, year, :movie), do: params ++ [year: year]
  defp maybe_add_year(params, year, :tv_show), do: params ++ [first_air_date_year: year]
  defp maybe_add_year(params, _year, _media_type), do: params

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp parse_search_results(%{"results" => results}) when is_list(results) do
    Enum.map(results, &parse_search_result/1)
  end

  defp parse_search_results(_), do: []

  defp parse_search_result(result) do
    SearchResult.from_api_response(result)
  end

  defp parse_metadata(data, media_type, provider_id) do
    MediaMetadata.from_api_response(data, media_type, provider_id)
  end

  defp parse_images(data) do
    ImagesResponse.from_api_response(data)
  end

  defp parse_image(image) do
    ImageData.from_api_response(image)
  end

  defp parse_season(data) do
    SeasonData.from_api_response(data)
  end

  defp parse_episode(episode) do
    EpisodeData.from_api_response(episode)
  end
end
