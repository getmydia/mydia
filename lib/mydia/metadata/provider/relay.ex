defmodule Mydia.Metadata.Provider.Relay do
  @moduledoc """
  Metadata provider adapter for metadata-relay service.

  This adapter interfaces with the metadata-relay service (https://metadata-relay.dorninger.co)
  which acts as a caching proxy for TMDB and TVDB APIs. Using the relay provides several benefits:

    * No API key required for basic usage
    * Built-in caching reduces redundant API calls
    * Rate limit protection from the relay's pooled quotas
    * Lower latency for frequently requested metadata

  ## Configuration

  The relay provider can be configured with custom relay endpoints:

      config = %{
        type: :metadata_relay,
        base_url: "https://metadata-relay.dorninger.co/tmdb",  # or /tvdb
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

  The relay uses TMDB-compatible endpoints:
    * `/search/multi` - Search across movies and TV shows
    * `/search/movie` - Search movies only
    * `/search/tv` - Search TV shows only
    * `/movie/{id}` - Get movie details
    * `/tv/{id}` - Get TV show details
    * `/movie/{id}/images` - Get movie images
    * `/tv/{id}/images` - Get TV show images
    * `/tv/{id}/season/{season_number}` - Get TV season details

  ## Image URLs

  The relay returns relative image paths (e.g., "/poster.jpg") which need to be
  prefixed with the TMDB image base URL. For TMDB images, use:

      https://image.tmdb.org/t/p/w500/poster.jpg (500px width)
      https://image.tmdb.org/t/p/original/poster.jpg (original size)

  Available sizes: w92, w154, w185, w342, w500, w780, original
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata.Provider.{Error, HTTP}

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
    append = Keyword.get(opts, :append_to_response, ["credits"])

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

    endpoint = "/tv/#{provider_id}/season/#{season_number}"
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

  ## Private Functions

  defp when_valid_query(query, callback) when is_binary(query) and byte_size(query) > 0 do
    callback.()
  end

  defp when_valid_query(_query, _callback) do
    {:error, Error.invalid_request("Query must be a non-empty string")}
  end

  defp search_endpoint(nil), do: "/search/multi"
  defp search_endpoint(:movie), do: "/search/movie"
  defp search_endpoint(:tv_show), do: "/search/tv"

  defp build_details_endpoint(:movie, id), do: "/movie/#{id}"
  defp build_details_endpoint(:tv_show, id), do: "/tv/#{id}"

  defp build_images_endpoint(:movie, id), do: "/movie/#{id}/images"
  defp build_images_endpoint(:tv_show, id), do: "/tv/#{id}/images"

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
    media_type = normalize_media_type(result["media_type"])
    title = get_title(result, media_type)
    year = extract_year(result, media_type)

    %{
      provider_id: to_string(result["id"]),
      provider: :metadata_relay,
      title: title,
      original_title: result["original_title"] || result["original_name"],
      year: year,
      media_type: media_type,
      overview: result["overview"],
      poster_path: result["poster_path"],
      backdrop_path: result["backdrop_path"],
      popularity: result["popularity"],
      vote_average: result["vote_average"],
      vote_count: result["vote_count"]
    }
  end

  defp parse_metadata(data, media_type, provider_id) do
    title = get_title(data, media_type)
    year = extract_year(data, media_type)
    release_date = parse_date(get_release_date(data, media_type))

    base_metadata = %{
      provider_id: to_string(provider_id),
      provider: :metadata_relay,
      title: title,
      original_title: data["original_title"] || data["original_name"],
      year: year,
      release_date: release_date,
      media_type: media_type,
      overview: data["overview"],
      tagline: data["tagline"],
      runtime: get_runtime(data, media_type),
      status: data["status"],
      genres: parse_genres(data["genres"]),
      poster_path: data["poster_path"],
      backdrop_path: data["backdrop_path"],
      popularity: data["popularity"],
      vote_average: data["vote_average"],
      vote_count: data["vote_count"],
      imdb_id: data["imdb_id"],
      production_companies: parse_names(data["production_companies"]),
      production_countries: parse_country_codes(data["production_countries"]),
      spoken_languages: parse_language_codes(data["spoken_languages"]),
      homepage: data["homepage"],
      cast: parse_cast(data["credits"]["cast"]),
      crew: parse_crew(data["credits"]["crew"])
    }

    case media_type do
      :tv_show ->
        Map.merge(base_metadata, %{
          number_of_seasons: data["number_of_seasons"],
          number_of_episodes: data["number_of_episodes"],
          episode_run_time: data["episode_run_time"],
          first_air_date: parse_date(data["first_air_date"]),
          last_air_date: parse_date(data["last_air_date"]),
          in_production: data["in_production"]
        })

      :movie ->
        base_metadata
    end
  end

  defp parse_images(%{"posters" => posters, "backdrops" => backdrops, "logos" => logos}) do
    %{
      posters: Enum.map(posters || [], &parse_image/1),
      backdrops: Enum.map(backdrops || [], &parse_image/1),
      logos: Enum.map(logos || [], &parse_image/1)
    }
  end

  defp parse_images(_), do: %{posters: [], backdrops: [], logos: []}

  defp parse_image(image) do
    %{
      file_path: image["file_path"],
      width: image["width"],
      height: image["height"],
      aspect_ratio: image["aspect_ratio"],
      vote_average: image["vote_average"],
      vote_count: image["vote_count"]
    }
  end

  defp parse_season(data) do
    %{
      season_number: data["season_number"],
      name: data["name"],
      overview: data["overview"],
      air_date: parse_date(data["air_date"]),
      poster_path: data["poster_path"],
      episode_count: length(data["episodes"] || []),
      episodes: Enum.map(data["episodes"] || [], &parse_episode/1)
    }
  end

  defp parse_episode(episode) do
    %{
      episode_number: episode["episode_number"],
      name: episode["name"],
      overview: episode["overview"],
      air_date: parse_date(episode["air_date"]),
      runtime: episode["runtime"],
      still_path: episode["still_path"],
      vote_average: episode["vote_average"],
      vote_count: episode["vote_count"]
    }
  end

  defp normalize_media_type("movie"), do: :movie
  defp normalize_media_type("tv"), do: :tv_show
  defp normalize_media_type(_), do: :movie

  defp get_title(data, :movie), do: data["title"] || data["name"]
  defp get_title(data, :tv_show), do: data["name"] || data["title"]
  defp get_title(data, _), do: data["title"] || data["name"]

  defp get_release_date(data, :movie), do: data["release_date"]
  defp get_release_date(data, :tv_show), do: data["first_air_date"]
  defp get_release_date(data, _), do: data["release_date"]

  defp get_runtime(data, :movie), do: data["runtime"]
  defp get_runtime(data, :tv_show), do: List.first(data["episode_run_time"] || [])
  defp get_runtime(_data, _), do: nil

  defp extract_year(_data, nil), do: nil

  defp extract_year(data, :movie) do
    case data["release_date"] do
      nil -> nil
      date when is_binary(date) -> extract_year_from_date(date)
      _ -> nil
    end
  end

  defp extract_year(data, :tv_show) do
    case data["first_air_date"] do
      nil -> nil
      date when is_binary(date) -> extract_year_from_date(date)
      _ -> nil
    end
  end

  defp extract_year_from_date(date_string) do
    case String.split(date_string, "-") do
      [year | _] ->
        case Integer.parse(year) do
          {year_int, ""} -> year_int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_genres(nil), do: []
  defp parse_genres(genres) when is_list(genres), do: Enum.map(genres, & &1["name"])
  defp parse_genres(_), do: []

  defp parse_names(nil), do: []
  defp parse_names(items) when is_list(items), do: Enum.map(items, & &1["name"])
  defp parse_names(_), do: []

  defp parse_country_codes(nil), do: []

  defp parse_country_codes(countries) when is_list(countries),
    do: Enum.map(countries, & &1["iso_3166_1"])

  defp parse_country_codes(_), do: []

  defp parse_language_codes(nil), do: []

  defp parse_language_codes(languages) when is_list(languages),
    do: Enum.map(languages, & &1["iso_639_1"])

  defp parse_language_codes(_), do: []

  defp parse_cast(nil), do: []

  defp parse_cast(cast) when is_list(cast) do
    cast
    |> Enum.take(20)
    |> Enum.map(fn member ->
      %{
        name: member["name"],
        character: member["character"],
        order: member["order"],
        profile_path: member["profile_path"]
      }
    end)
  end

  defp parse_cast(_), do: []

  defp parse_crew(nil), do: []

  defp parse_crew(crew) when is_list(crew) do
    crew
    |> Enum.filter(fn member ->
      member["job"] in ["Director", "Producer", "Writer", "Screenplay"]
    end)
    |> Enum.take(10)
    |> Enum.map(fn member ->
      %{
        name: member["name"],
        job: member["job"],
        department: member["department"],
        profile_path: member["profile_path"]
      }
    end)
  end

  defp parse_crew(_), do: []
end
