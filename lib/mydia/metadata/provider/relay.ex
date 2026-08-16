defmodule Mydia.Metadata.Provider.Relay do
  @moduledoc """
  Metadata provider adapter for metadata-relay service.

  This adapter interfaces with the self-hosted metadata-relay service
  (defaults to https://relay.mydia.dev, configurable via `METADATA_RELAY_URL`)
  which acts as a caching proxy for TMDB and TVDB APIs.
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
        base_url: "https://relay.mydia.dev",
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

  require Logger
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.{Error, HTTP}
  alias Mydia.Metadata.LanguageCode
  alias Mydia.Metadata.ProviderIDRegistry

  alias Mydia.Metadata.Structs.{
    ImageData,
    SearchResult,
    MediaMetadata,
    SeasonData,
    ImagesResponse,
    Collection,
    Video
  }

  @default_language "en-US"

  # Resolves the language to use for a request: explicit per-call opt wins,
  # then the language configured on the provider config (typically populated
  # from `Mydia.Metadata.metadata_language/0`), then the module default.
  defp config_language(config) do
    case config do
      %{options: %{language: lang}} when is_binary(lang) and lang != "" -> lang
      _ -> @default_language
    end
  end

  defp resolve_language(config, opts) do
    Keyword.get(opts, :language, config_language(config))
  end

  # Ordered list of TVDB codes to try when selecting a translation: configured
  # language, then the show's original language, then English. Each language
  # expands to its 3-letter and 2-letter candidates because TVDB's translation
  # keys are inconsistent (e.g. Portuguese as both "por" and "pt").
  defp tvdb_preferred_codes(language, original_language) do
    (LanguageCode.tvdb_candidates(language) ++
       LanguageCode.tvdb_candidates(original_language) ++
       ["eng"])
    |> Enum.uniq()
  end

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
      provider = Keyword.get(opts, :provider)

      # TV shows route to TVDB by default; an explicit `provider: :tmdb` forces
      # TMDB. Movies always use TMDB regardless of provider. Absent a provider
      # opt, behavior is unchanged (TV -> TVDB), preserving existing callers.
      if media_type == :tv_show && provider != :tmdb do
        search_tvdb(config, query, opts)
      else
        search_tmdb(config, query, opts)
      end
    end)
  end

  defp search_tmdb(config, query, opts) do
    media_type = Keyword.get(opts, :media_type)
    year = Keyword.get(opts, :year)
    language = resolve_language(config, opts)
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
        results = parse_search_results(body, media_type)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Search failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp search_tvdb(config, query, opts) do
    year = Keyword.get(opts, :year)

    params =
      [query: query, type: "series"]
      |> maybe_add_param(:year, year)

    req = HTTP.new_request(config)

    case HTTP.get(req, "/tvdb/search", params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_tvdb_search_results(body)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("TVDB search failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_by_id(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    provider = Keyword.get(opts, :provider)

    # Route to TVDB for TV shows by default, or when explicitly requested
    if provider == :tvdb || (media_type == :tv_show && provider != :tmdb) do
      fetch_tvdb_by_id(config, provider_id, opts)
    else
      fetch_tmdb_by_id(config, provider_id, media_type, opts)
    end
  end

  # Fetch from TMDB (default behavior)
  defp fetch_tmdb_by_id(config, provider_id, media_type, opts) do
    # Validate that the provider ID matches the requested media type
    case ProviderIDRegistry.validate_id_type(provider_id, :tmdb, media_type) do
      :ok ->
        # Validation passed, proceed with fetch
        perform_tmdb_fetch(config, provider_id, media_type, opts)

      {:error, :type_mismatch, actual_type} ->
        # Known ID with wrong type - skip the request
        Logger.warning(
          "Skipping TMDB fetch: provider ID belongs to different media type",
          provider_id: provider_id,
          requested_type: media_type,
          actual_type: actual_type
        )

        {:error,
         Error.invalid_request(
           "Provider ID #{provider_id} is a #{actual_type}, not a #{media_type}"
         )}
    end
  end

  # Perform the actual TMDB fetch after validation
  defp perform_tmdb_fetch(config, provider_id, media_type, opts) do
    language = resolve_language(config, opts)

    append =
      Keyword.get(opts, :append_to_response, [
        "credits",
        "alternative_titles",
        "videos",
        "external_ids"
      ])

    endpoint = build_details_endpoint(media_type, provider_id)

    params = [
      language: language,
      append_to_response: Enum.join(append, ",")
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        # Successful fetch - record the ID→type mapping
        ProviderIDRegistry.record_id_type(provider_id, :tmdb, media_type)
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

  # Fetch from TVDB
  defp fetch_tvdb_by_id(config, provider_id, opts) do
    media_type = Keyword.get(opts, :media_type, :tv_show)

    # Validate that the provider ID matches the requested media type
    case ProviderIDRegistry.validate_id_type(provider_id, :tvdb, media_type) do
      :ok ->
        # Validation passed, proceed with fetch
        perform_tvdb_fetch(config, provider_id, media_type, opts)

      {:error, :type_mismatch, actual_type} ->
        # Known ID with wrong type - skip the request
        Logger.warning(
          "Skipping TVDB fetch: provider ID belongs to different media type",
          provider_id: provider_id,
          requested_type: media_type,
          actual_type: actual_type
        )

        {:error,
         Error.invalid_request(
           "Provider ID #{provider_id} is a #{actual_type}, not a #{media_type}"
         )}
    end
  end

  # Perform the actual TVDB fetch after validation
  defp perform_tvdb_fetch(config, provider_id, media_type, opts) do
    # Use extended endpoint to get more details including seasons
    endpoint = "/tvdb/series/#{provider_id}/extended"
    language = resolve_language(config, opts)

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: [meta: "translations"]) do
      {:ok, %{status: 200, body: body}} ->
        # Successful fetch - record the ID→type mapping
        ProviderIDRegistry.record_id_type(provider_id, :tvdb, media_type)
        # TVDB wraps response in "data" key
        data = body["data"] || body
        # Transform TVDB response to TMDB-like format for parsing
        transformed = transform_tvdb_to_tmdb_format(data, media_type, language)
        metadata = parse_metadata(transformed, media_type, provider_id)
        # Override provider to :tvdb. Trailers live outside the transformed
        # payload, so videos are resolved separately.
        preferred = tvdb_preferred_codes(language, data["originalLanguage"])

        metadata = %{
          metadata
          | provider: :tvdb,
            videos: resolve_tvdb_videos(config, data, preferred, language)
        }

        {:ok, metadata}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("TVDB series not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("TVDB fetch failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  # TVDB's own `trailers` array is sparse — popular shows such as Game of
  # Thrones and Stranger Things carry none — so fall back to TMDB's videos via
  # the cross-reference TVDB publishes in `remoteIds`. A missing trailer must
  # never fail the fetch, so every failure path degrades to an empty list.
  defp resolve_tvdb_videos(config, data, preferred_codes, language) do
    case Video.from_tvdb_trailers(data["trailers"], preferred_codes) do
      [] ->
        # Degrade here, outside the cache boundary, rather than inside the
        # memoized fetch. A relay failure has to stay an error until it is past
        # `Cache.fetch/3`, otherwise one transient 500 is stored as a
        # confirmed-empty result and suppresses the trailer for 24 hours.
        case fetch_tmdb_videos_for_tvdb(config, data, language) do
          {:ok, videos} when is_list(videos) -> videos
          _ -> []
        end

      videos ->
        videos
    end
  end

  defp fetch_tmdb_videos_for_tvdb(config, data, language) do
    case tmdb_id_from_remote_ids(data["remoteIds"]) do
      nil ->
        Logger.debug("No TMDB cross-reference in TVDB remoteIds; leaving videos empty",
          tvdb_id: data["id"]
        )

        {:ok, []}

      tmdb_id ->
        fetch_tmdb_videos(config, tmdb_id, language)
    end
  end

  # The spec's coverage sample found zero TVDB trailers on 4 of 4 popular shows,
  # so this fallback is the typical path rather than the exception. Memoize it so
  # a weekly `MetadataRefresh.refresh_all_media/0` doesn't cost one extra relay
  # round-trip per TV show. `Cache.fetch/3` stores only `{:ok, _}`, which is
  # exactly the split we want: a successful empty list is cached (since "neither
  # provider has a trailer" is the case that would otherwise re-request
  # forever), while an error is returned uncached and retried next time.
  defp fetch_tmdb_videos(config, tmdb_id, language) do
    cache_key = "tvdb_tmdb_videos:#{tmdb_id}:#{language}"

    Cache.fetch(cache_key, fn -> request_tmdb_videos(config, tmdb_id) end, ttl: :timer.hours(24))
  end

  defp request_tmdb_videos(config, tmdb_id) do
    case perform_tmdb_fetch(config, tmdb_id, :tv_show, append_to_response: ["videos"]) do
      {:ok, %MediaMetadata{videos: videos}} when is_list(videos) ->
        {:ok, videos}

      {:error, _reason} = error ->
        Logger.debug("TMDB trailer fallback failed; leaving it uncached",
          tmdb_id: tmdb_id,
          result: inspect(error)
        )

        error

      other ->
        Logger.debug("TMDB trailer fallback returned no videos",
          tmdb_id: tmdb_id,
          result: inspect(other)
        )

        {:ok, []}
    end
  end

  # The `is_binary(id)` guard is load-bearing, not defensive noise. `remoteIds`
  # is untyped relay-forwarded JSON, and a non-string id would flow into
  # `ProviderIDRegistry.record_id_type/3`, whose `is_binary(provider_id)` guard
  # would raise FunctionClauseError from inside the TVDB fetch — turning a
  # missing trailer into a failed TV show fetch.
  defp tmdb_id_from_remote_ids(remote_ids) when is_list(remote_ids),
    do: find_remote_id(remote_ids, "TheMovieDB.com")

  defp tmdb_id_from_remote_ids(_), do: nil

  defp find_remote_id(remote_ids, source) when is_list(remote_ids) do
    Enum.find_value(remote_ids, fn
      %{"sourceName" => ^source, "id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end)
  end

  defp find_remote_id(_remote_ids, _source), do: nil

  # Transform TVDB API response to match TMDB format for consistent parsing
  defp transform_tvdb_to_tmdb_format(data, _media_type, language) when is_map(data) do
    # Extract year from firstAired date or year field
    year = extract_tvdb_year(data)

    # Transform seasons if present
    seasons = transform_tvdb_seasons(data["seasons"])

    # Transform genres
    genres = transform_tvdb_genres(data["genres"])

    # Select localized title/overview from the translation bundle, preferring
    # the configured language, then the show's original language, then English.
    translations = data["translations"] || %{}
    preferred = tvdb_preferred_codes(language, data["originalLanguage"])

    localized_name =
      LanguageCode.select_translation(translations["nameTranslations"], "name", preferred)

    localized_overview =
      LanguageCode.select_translation(translations["overviewTranslations"], "overview", preferred)

    remote_ids = List.wrap(data["remoteIds"])

    # Build TMDB-like response
    %{
      "id" => data["id"],
      "name" => localized_name || data["name"],
      "original_name" => data["originalName"] || data["name"],
      "overview" => localized_overview || data["overview"],
      "first_air_date" => data["firstAired"],
      "last_air_date" => data["lastAired"],
      "status" => get_in(data, ["status", "name"]),
      "poster_path" => transform_tvdb_image(data["image"]),
      "backdrop_path" => transform_tvdb_artwork(data["artworks"], "background"),
      "genres" => genres,
      "popularity" => data["score"],
      "vote_average" => nil,
      "number_of_seasons" => length(seasons),
      "number_of_episodes" => data["episodes"] |> List.wrap() |> length(),
      "in_production" => get_in(data, ["status", "name"]) == "Continuing",
      "seasons" => seasons,
      # Include year for compatibility
      "year" => year,
      # Classification fields for category auto-detection
      "origin_country" => transform_tvdb_origin_country(data["originalCountry"]),
      "original_language" => data["originalLanguage"],
      # TVDB publishes the TMDB and IMDB cross-references here. Emitting them
      # under the TMDB response's own key means MediaMetadata has one parser
      # for both providers. `tvdb_id` is deliberately absent: this map holds
      # the ids of *other* providers, and the TVDB id is the one we queried by.
      "external_ids" => %{
        "tmdb_id" => find_remote_id(remote_ids, "TheMovieDB.com"),
        "imdb_id" => find_remote_id(remote_ids, "IMDB")
      }
    }
  end

  defp transform_tvdb_to_tmdb_format(data, _media_type, _language), do: data

  defp extract_tvdb_year(%{"year" => year}) when is_binary(year) do
    case Integer.parse(year) do
      {y, _} -> y
      :error -> nil
    end
  end

  defp extract_tvdb_year(%{"firstAired" => first_aired}) when is_binary(first_aired) do
    case String.split(first_aired, "-") do
      [year | _] ->
        case Integer.parse(year) do
          {y, _} -> y
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_tvdb_year(_), do: nil

  defp transform_tvdb_seasons(nil), do: []

  defp transform_tvdb_seasons(seasons) when is_list(seasons) do
    seasons
    |> Enum.filter(fn s -> s["type"]["type"] == "official" end)
    |> Enum.map(fn s ->
      %{
        "id" => s["id"],
        "season_number" => s["number"],
        "name" => s["name"] || "Season #{s["number"]}",
        "overview" => s["overview"],
        "poster_path" => transform_tvdb_image(s["image"]),
        "air_date" => nil,
        "episode_count" => s["episodeCount"] || 0,
        "tvdb_season_id" => s["id"]
      }
    end)
  end

  defp transform_tvdb_seasons(_), do: []

  defp transform_tvdb_genres(nil), do: []

  defp transform_tvdb_genres(genres) when is_list(genres) do
    Enum.map(genres, fn g ->
      %{"id" => g["id"], "name" => g["name"]}
    end)
  end

  defp transform_tvdb_genres(_), do: []

  # TVDB returns originalCountry as a string, convert to list for consistency with TMDB
  defp transform_tvdb_origin_country(nil), do: []
  defp transform_tvdb_origin_country(country) when is_binary(country), do: [country]
  defp transform_tvdb_origin_country(countries) when is_list(countries), do: countries
  defp transform_tvdb_origin_country(_), do: []

  # TVDB images are full URLs or relative paths
  defp transform_tvdb_image(nil), do: nil

  defp transform_tvdb_image(url) when is_binary(url) do
    # If it's already a full URL, return as-is
    # The metadata system will handle it appropriately
    url
  end

  defp transform_tvdb_image(_), do: nil

  # TVDB artwork type IDs returned as integers by the API
  @tvdb_artwork_type_ids %{
    "background" => 3,
    "poster" => 2,
    "banner" => 1
  }

  # Extract specific artwork type from artworks list
  defp transform_tvdb_artwork(nil, _type), do: nil

  defp transform_tvdb_artwork(artworks, type) when is_list(artworks) do
    type_id = Map.get(@tvdb_artwork_type_ids, type)

    artwork =
      Enum.find(artworks, fn
        # Handle artwork as a map with type info
        %{"type" => type_info} when is_map(type_info) ->
          type_info["name"] == type

        %{"type" => artwork_type} when is_binary(artwork_type) ->
          artwork_type == type

        # Handle integer type IDs from TVDB API
        %{"type" => artwork_type_id} when is_integer(artwork_type_id) and not is_nil(type_id) ->
          artwork_type_id == type_id

        _ ->
          false
      end)

    case artwork do
      %{"image" => image} -> image
      %{"url" => url} -> url
      _ -> nil
    end
  end

  defp transform_tvdb_artwork(_, _), do: nil

  @impl true
  def fetch_images(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    provider = Keyword.get(opts, :provider)

    if provider == :tvdb || (media_type == :tv_show && provider != :tmdb) do
      fetch_tvdb_images(config, provider_id)
    else
      fetch_tmdb_images(config, provider_id, media_type, opts)
    end
  end

  defp fetch_tmdb_images(config, provider_id, media_type, opts) do
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

  defp fetch_tvdb_images(config, provider_id) do
    # TVDB images come from the extended series endpoint artworks
    endpoint = "/tvdb/series/#{provider_id}/extended"

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: []) do
      {:ok, %{status: 200, body: body}} ->
        data = body["data"] || body
        images = parse_tvdb_artworks(data["artworks"])
        {:ok, images}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("TVDB series not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("TVDB fetch images failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  defp parse_tvdb_artworks(nil), do: ImagesResponse.new(%{posters: [], backdrops: [], logos: []})

  defp parse_tvdb_artworks(artworks) when is_list(artworks) do
    {posters, backdrops} =
      Enum.reduce(artworks, {[], []}, fn artwork, {posters, backdrops} ->
        type_name =
          case artwork["type"] do
            %{"name" => name} -> name
            name when is_binary(name) -> name
            _ -> nil
          end

        image_url = artwork["image"] || artwork["url"]

        case type_name do
          "poster" ->
            img =
              ImageData.new(
                file_path: image_url,
                width: artwork["width"],
                height: artwork["height"]
              )

            {[img | posters], backdrops}

          "background" ->
            img =
              ImageData.new(
                file_path: image_url,
                width: artwork["width"],
                height: artwork["height"]
              )

            {posters, [img | backdrops]}

          _ ->
            {posters, backdrops}
        end
      end)

    %ImagesResponse{
      posters: Enum.reverse(posters),
      backdrops: Enum.reverse(backdrops),
      logos: []
    }
  end

  defp parse_tvdb_artworks(_), do: ImagesResponse.new(%{posters: [], backdrops: [], logos: []})

  @impl true
  def fetch_season(config, provider_id, season_number, opts \\ []) do
    tvdb_season_id = Keyword.get(opts, :tvdb_season_id)

    if tvdb_season_id do
      fetch_season_tvdb(config, tvdb_season_id, opts)
    else
      fetch_season_tmdb(config, provider_id, season_number, opts)
    end
  end

  defp fetch_season_tmdb(config, provider_id, season_number, opts) do
    language = resolve_language(config, opts)

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

  defp fetch_season_tvdb(config, tvdb_season_id, opts) do
    endpoint = "/tvdb/seasons/#{tvdb_season_id}/extended"
    language = resolve_language(config, opts)
    preferred = tvdb_preferred_codes(language, Keyword.get(opts, :original_language))

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: [meta: "translations"]) do
      {:ok, %{status: 200, body: body}} ->
        data = body["data"] || body
        # Episodes in the season response don't include translation text,
        # only language code arrays. Fetch each episode's translations individually.
        data = enrich_tvdb_episodes_with_translations(req, data)
        season = SeasonData.from_tvdb_response(data, preferred)
        {:ok, season}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("TVDB season not found: #{tvdb_season_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("TVDB fetch season failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  # Bound each episode translation fetch. `:infinity` let a single hung
  # Bypass/relay request pin the whole ExUnit case until the 60s wall clock.
  @episode_translation_timeout_ms 15_000

  # TVDB season extended responses include episodes but without translation text.
  # Fetch each episode's extended data to get its translation bundle (all languages).
  defp enrich_tvdb_episodes_with_translations(req, data) do
    episodes = data["episodes"] || []

    if episodes == [] do
      data
    else
      enriched =
        episodes
        |> Task.async_stream(
          fn ep -> fetch_tvdb_episode_translations(req, ep) end,
          max_concurrency: 5,
          timeout: @episode_translation_timeout_ms,
          on_timeout: :kill_task
        )
        |> Enum.zip(episodes)
        |> Enum.map(fn
          {{:ok, ep}, _orig} ->
            ep

          {{:exit, reason}, orig} ->
            Logger.warning(
              "TVDB episode translation fetch exited; keeping untranslated episode",
              episode_id: orig["id"],
              reason: inspect(reason)
            )

            orig
        end)

      Map.put(data, "episodes", enriched)
    end
  end

  # Fetch an individual episode's extended data to get its translations.
  # Merges the translations key into the episode map so from_tvdb_response can
  # select the configured language.
  defp fetch_tvdb_episode_translations(req, episode) do
    ep_id = episode["id"]

    if ep_id do
      case HTTP.get(req, "/tvdb/episodes/#{ep_id}/extended", params: [meta: "translations"]) do
        {:ok, %{status: 200, body: body}} ->
          ep_data = body["data"] || body
          Map.put(episode, "translations", ep_data["translations"])

        _ ->
          episode
      end
    else
      episode
    end
  end

  @impl true
  def fetch_trending(config, opts \\ []) do
    media_type = Keyword.get(opts, :media_type)
    language = resolve_language(config, opts)
    page = Keyword.get(opts, :page, 1)

    endpoint = build_trending_endpoint(media_type)

    params = [
      language: language,
      page: page
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body, media_type)
        {:ok, results}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch trending failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Fetches a curated list (trending, popular, upcoming, now_playing, on_the_air, airing_today).

  Returns `{:ok, %{results: [SearchResult], page: int, total_pages: int}}`.
  """
  def fetch_curated(config, list_type, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    language = resolve_language(config, opts)
    page = Keyword.get(opts, :page, 1)

    endpoint = build_curated_endpoint(list_type, media_type)

    params = [
      language: language,
      page: page
    ]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body, media_type)
        total_pages = body["total_pages"] || 1

        {:ok, %{results: results, page: page, total_pages: total_pages}}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Error.api_error("Fetch curated list failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Discovers media with filters (genre, year, language, rating, sort).

  Returns `{:ok, %{results: [SearchResult], page: int, total_pages: int}}`.
  """
  def fetch_discover(config, media_type, opts \\ []) do
    language = resolve_language(config, opts)
    page = Keyword.get(opts, :page, 1)
    genres = Keyword.get(opts, :genres)
    original_language = Keyword.get(opts, :original_language)
    year = Keyword.get(opts, :year)
    min_rating = Keyword.get(opts, :min_rating)
    sort_by = Keyword.get(opts, :sort_by, "popularity.desc")

    endpoint =
      case media_type do
        :tv_show -> "/tmdb/tv/discover"
        _ -> "/tmdb/movies/discover"
      end

    params =
      [language: language, page: page, sort_by: sort_by]
      |> maybe_add_param(:with_genres, genres)
      |> maybe_add_param(:with_original_language, original_language)
      |> maybe_add_param(year_param_key(media_type), year)
      |> maybe_add_param(:"vote_average.gte", min_rating)

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        results = parse_search_results(body, media_type)
        total_pages = body["total_pages"] || 1

        {:ok, %{results: results, page: page, total_pages: total_pages}}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Discover failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Fetches a TMDB movie collection (franchise) and its member movies.

  Not a `Mydia.Metadata.Provider` callback: TVDB has no equivalent concept, so
  this stays specific to the relay adapter.

  A relay deployment that predates this endpoint answers 404, which surfaces as
  `{:error, %Error{type: :not_found}}` and is treated by callers as "no franchise
  data available".

  Returns `{:ok, %Collection{}}`.
  """
  def fetch_collection(config, collection_id, opts \\ []) do
    language = resolve_language(config, opts)
    endpoint = "/tmdb/collections/#{collection_id}"

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: [language: language]) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, Collection.from_api_response(body)}

      {:ok, %{status: 200, body: _}} ->
        {:error, Error.api_error("Collection response was not an object")}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Collection not found: #{collection_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch collection failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Fetches TMDB's recommendations for a movie or TV show.

  TMDB exposes recommendations as a sub-object of the details endpoint rather than
  as a standalone route the relay proxies, so this rides `append_to_response` on
  the endpoint the relay already serves. That is what lets the feature ship
  without a relay release.

  The sub-object uses the same `%{"results" => [...]}` envelope as search and
  trending, so `parse_search_results/2` consumes it unchanged. A response with no
  `recommendations` key falls through that function's catch-all to `[]`, which is
  why a missing sub-object is a normal empty result rather than an error.

  ## Options
    * `:media_type` - `:movie` or `:tv_show` (default: `:movie`)
    * `:language` - overrides the configured language

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Relay.fetch_recommendations(config, "965150", media_type: :movie)
      {:ok, [%Mydia.Metadata.Structs.SearchResult{title: "The Eternal Daughter"}]}
  """
  @spec fetch_recommendations(map(), String.t(), keyword()) ::
          {:ok, [SearchResult.t()]} | {:error, Error.t()}
  def fetch_recommendations(config, provider_id, opts \\ []) do
    media_type = Keyword.get(opts, :media_type, :movie)
    language = resolve_language(config, opts)

    endpoint = build_details_endpoint(media_type, provider_id)
    params = [language: language, append_to_response: "recommendations"]

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: params) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_search_results(body["recommendations"], media_type)}

      {:ok, %{status: 404}} ->
        {:error, Error.not_found("Media not found: #{provider_id}")}

      {:ok, %{status: status, body: body}} ->
        {:error,
         Error.api_error("Fetch recommendations failed with status #{status}", %{body: body})}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Fetches the list of genres for a media type.

  Returns `{:ok, [%{id: integer, name: string}]}`.
  """
  def fetch_genres(config, media_type) do
    endpoint =
      case media_type do
        :tv_show -> "/tmdb/genre/tv"
        _ -> "/tmdb/genre/movie"
      end

    req = HTTP.new_request(config)

    case HTTP.get(req, endpoint, params: []) do
      {:ok, %{status: 200, body: %{"genres" => genres}}} when is_list(genres) ->
        parsed =
          Enum.map(genres, fn g ->
            %{id: g["id"], name: g["name"]}
          end)

        {:ok, parsed}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: status, body: body}} ->
        {:error, Error.api_error("Fetch genres failed with status #{status}", %{body: body})}

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

  defp build_curated_endpoint(:trending, media_type), do: build_trending_endpoint(media_type)
  defp build_curated_endpoint(:popular, :tv_show), do: "/tmdb/tv/popular"
  defp build_curated_endpoint(:popular, _), do: "/tmdb/movies/popular"
  defp build_curated_endpoint(:upcoming, _), do: "/tmdb/movies/upcoming"
  defp build_curated_endpoint(:now_playing, _), do: "/tmdb/movies/now_playing"
  defp build_curated_endpoint(:on_the_air, _), do: "/tmdb/tv/on_the_air"
  defp build_curated_endpoint(:airing_today, _), do: "/tmdb/tv/airing_today"

  defp year_param_key(:tv_show), do: :first_air_date_year
  defp year_param_key(_), do: :primary_release_year

  defp maybe_add_year(params, nil, _media_type), do: params
  defp maybe_add_year(params, year, :movie), do: params ++ [year: year]
  defp maybe_add_year(params, year, :tv_show), do: params ++ [first_air_date_year: year]
  defp maybe_add_year(params, _year, _media_type), do: params

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp parse_search_results(%{"results" => results}, media_type) when is_list(results) do
    Enum.map(results, &parse_search_result(&1, media_type))
  end

  defp parse_search_results(_, _media_type), do: []

  defp parse_search_result(result, media_type) do
    # Pass media_type from search options to override API response's media_type
    # This is needed because endpoint-specific searches (e.g., /tmdb/tv/search)
    # don't include media_type in each result
    search_result = SearchResult.from_api_response(result, media_type: media_type)

    # Record the ID→type mapping from search results
    # This helps prevent future 404s from type mismatches
    if search_result.provider_id && media_type do
      ProviderIDRegistry.record_id_type(
        to_string(search_result.provider_id),
        :tmdb,
        media_type
      )
    end

    search_result
  end

  defp parse_tvdb_search_results(%{"data" => results}) when is_list(results) do
    Enum.map(results, &parse_tvdb_search_result/1)
  end

  defp parse_tvdb_search_results(_), do: []

  defp parse_tvdb_search_result(data) when is_map(data) do
    provider_id = to_string(data["tvdb_id"] || data["id"])

    year =
      case data["year"] do
        y when is_binary(y) ->
          case Integer.parse(y) do
            {n, _} -> n
            :error -> extract_year_from_tvdb_date(data["first_air_time"])
          end

        y when is_integer(y) ->
          y

        _ ->
          extract_year_from_tvdb_date(data["first_air_time"])
      end

    # Prefer English translation over the native-language name
    translations = data["translations"] || %{}
    english_title = translations["eng"]
    display_title = english_title || data["name"]

    # Prefer English overview over the native-language overview
    overviews = data["overviews"] || %{}
    english_overview = overviews["eng"]
    display_overview = english_overview || data["overview"]

    # Record the ID→type mapping for TVDB
    ProviderIDRegistry.record_id_type(provider_id, :tvdb, :tv_show)

    %SearchResult{
      provider_id: provider_id,
      provider: :tvdb,
      media_type: :tv_show,
      title: display_title,
      name: display_title,
      original_title: data["name"],
      year: year,
      overview: display_overview,
      poster_path: data["image_url"],
      first_air_date: data["first_air_time"],
      id: data["tvdb_id"] || data["id"]
    }
  end

  defp extract_year_from_tvdb_date(nil), do: nil

  defp extract_year_from_tvdb_date(date) when is_binary(date) do
    case String.split(date, "-") do
      [year | _] ->
        case Integer.parse(year) do
          {y, _} -> y
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_year_from_tvdb_date(_), do: nil

  defp parse_metadata(data, media_type, provider_id) do
    MediaMetadata.from_api_response(data, media_type, provider_id)
  end

  defp parse_images(data) do
    ImagesResponse.from_api_response(data)
  end

  defp parse_season(data) do
    SeasonData.from_api_response(data)
  end
end
