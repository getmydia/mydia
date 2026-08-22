defmodule Mydia.Metadata do
  @moduledoc """
  The Metadata context handles metadata provider operations.

  This module provides the main API for searching and fetching metadata from
  configured metadata providers (TMDB, TVDB, metadata-relay, etc.).

  ## Adapter Registration

  Metadata provider adapters must be registered before they can be used.
  Registration happens automatically at application startup via `register_providers/0`.

  ## Searching

  To search for media:

      config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      Mydia.Metadata.search(config, "The Matrix", media_type: :movie)

  ## Fetching Metadata

  To fetch detailed metadata:

      Mydia.Metadata.fetch_by_id(config, "603", media_type: :movie)

  ## Configuration

  Provider configurations can be stored in the database via the Settings context
  or passed directly as maps. The configuration should include:

    * `:type` - Provider type (`:metadata_relay`, `:tmdb`, `:tvdb`)
    * `:base_url` - Base URL for the provider API
    * `:api_key` - API key (if required, not needed for metadata-relay)
    * `:options` - Provider-specific options map
  """

  require Logger

  # Fallback language when neither opts nor the provider config specify one.
  # Must agree with the relay provider's default so cache keys and fetches align.
  @default_language "en-US"

  alias Mydia.Metadata.Provider

  @doc """
  Registers all known metadata provider adapters with the registry.

  This function is called automatically during application startup.
  Adapters must be registered before they can be used.

  ## Registered Providers

  Currently supported providers:
    - `:metadata_relay` - metadata-relay proxy service (recommended)
    - `:tmdb` - The Movie Database API (when implemented)
    - `:tvdb` - The TV Database API (when implemented)
  """
  def register_providers do
    Logger.info("Registering metadata provider adapters...")

    # Register metadata-relay as the primary provider
    Provider.Registry.register(:metadata_relay, Mydia.Metadata.Provider.Relay)

    # Additional providers will be registered as they are implemented
    # Provider.Registry.register(:tmdb, Mydia.Metadata.Provider.TMDB)
    # Provider.Registry.register(:tvdb, Mydia.Metadata.Provider.TVDB)

    Logger.info("Metadata provider adapter registration complete")
    :ok
  end

  @doc """
  Tests the connection to a metadata provider.

  ## Parameters
    - `config` - Provider configuration map

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.test_connection(config)
      {:ok, %{status: "ok", provider: "metadata_relay"}}
  """
  def test_connection(%{type: type} = config) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.test_connection(config)
    end
  end

  @doc """
  Searches for media by title and optional parameters.

  ## Parameters
    - `config` - Provider configuration map
    - `query` - Search query string
    - `opts` - Search options (see `Mydia.Metadata.Provider` for available options)

  ## Options
    * `:media_type` - Filter by media type (`:movie`, `:tv_show`)
    * `:year` - Filter by release year
    * `:language` - Language for results (default: "en-US")
    * `:page` - Page number for pagination (default: 1)

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.search(config, "The Matrix", media_type: :movie, year: 1999)
      {:ok, [%{provider_id: "603", title: "The Matrix", ...}]}
  """
  def search(%{type: type} = config, query, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.search(config, query, opts)
    end
  end

  @doc """
  Searches for media with caching to reduce API calls.

  This is a cached wrapper around `search/3` that caches results
  for 1 hour to reduce redundant API calls.

  Results are cached by query, media_type, year, and language.

  ## Parameters
    - `config` - Provider configuration map
    - `query` - Search query string
    - `opts` - Search options (see `Mydia.Metadata.Provider` for available options)

  ## Options
    * `:media_type` - Filter by media type (`:movie`, `:tv_show`)
    * `:year` - Filter by release year
    * `:language` - Language for results (default: "en-US")
    * `:page` - Page number for pagination (default: 1)

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.search_cached(config, "The Matrix", media_type: :movie, year: 1999)
      {:ok, [%{provider_id: "603", title: "The Matrix", ...}]}
  """
  def search_cached(%{type: type} = config, query, opts \\ []) when is_atom(type) do
    alias Mydia.Metadata.Cache

    # Build cache key including all relevant search parameters
    media_type = Keyword.get(opts, :media_type)
    year = Keyword.get(opts, :year)
    # Default to the configured language so searches don't read English-cached
    # results (mirrors fetch_by_id_cached/3 and fetch_season_cached/4).
    language = Keyword.get(opts, :language, config_language(config))
    page = Keyword.get(opts, :page, 1)
    # Include the provider so a TV title searched under TVDB and under TMDB
    # never share a cache entry (per-library provider routing). Mirrors the
    # provider-aware key in fetch_by_id_cached/3.
    provider = Keyword.get(opts, :provider, type)

    # Create a stable cache key from query and options
    cache_key = "search:#{provider}:#{query}:#{media_type}:#{year}:#{language}:#{page}"

    # Cache for 1 hour
    Cache.fetch(
      cache_key,
      fn ->
        search(config, query, opts)
      end,
      ttl: :timer.hours(1)
    )
  end

  @doc """
  Fetches detailed metadata for a specific media item by provider ID.

  ## Parameters
    - `config` - Provider configuration map
    - `provider_id` - Provider-specific ID for the media item
    - `opts` - Fetch options (see `Mydia.Metadata.Provider` for available options)

  ## Options
    * `:media_type` - Media type (`:movie` or `:tv_show`, default: `:movie`)
    * `:language` - Language for results (default: "en-US")
    * `:append_to_response` - Additional data to include (e.g., ["credits", "images"])

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.fetch_by_id(config, "603", media_type: :movie)
      {:ok, %{provider_id: "603", title: "The Matrix", runtime: 136, ...}}
  """
  def fetch_by_id(%{type: type} = config, provider_id, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.fetch_by_id(config, provider_id, opts)
    end
  end

  @doc """
  Fetches detailed metadata with caching to reduce API calls.

  This is a cached wrapper around `fetch_by_id/3` that caches results
  for 1 hour to reduce redundant API calls during bulk imports.

  Results are cached by provider_id, media_type, and append_to_response.

  ## Parameters
    - `config` - Provider configuration map
    - `provider_id` - Provider-specific ID for the media item
    - `opts` - Fetch options (same as `fetch_by_id/3`)

  ## Examples

      iex> config = Mydia.Metadata.default_relay_config()
      iex> Mydia.Metadata.fetch_by_id_cached(config, "603", media_type: :movie)
      {:ok, %{provider_id: "603", title: "The Matrix", ...}}
  """
  def fetch_by_id_cached(%{type: type} = config, provider_id, opts \\ []) when is_atom(type) do
    alias Mydia.Metadata.Cache

    media_type = Keyword.get(opts, :media_type, :movie)
    append = Keyword.get(opts, :append_to_response, []) |> Enum.sort() |> Enum.join(",")
    # Default to the configured language (not a literal "en-US") so cache keys
    # vary by language and non-English libraries don't read English-cached entries.
    language = Keyword.get(opts, :language, config_language(config))
    # Include the provider so numerically-overlapping TVDB/TMDB ids never share a
    # cache entry (e.g. TVDB series 603 vs TMDB movie 603).
    provider = Keyword.get(opts, :provider, type)
    # The TVDB orderings of one series differ only in how the seasons list
    # groups the same episodes, so two orderings of the same show would
    # otherwise share a cache entry and the second caller would silently get
    # the first one's grouping.
    season_order = Mydia.Media.SeasonOrder.tvdb_type(Keyword.get(opts, :season_order))

    cache_key =
      "fetch_by_id:#{provider}:#{provider_id}:#{media_type}:#{language}:#{append}:#{season_order}"

    Cache.fetch(
      cache_key,
      fn ->
        fetch_by_id(config, provider_id, opts)
      end,
      ttl: :timer.hours(1)
    )
  end

  @doc """
  Fetches a movie collection (franchise) with its member movies, cached in ETS.

  Cached for 24 hours: franchises gain a member every few years, and the page
  that reads this is opened often.

  The language is part of the cache key for the same reason it is in
  `fetch_by_id_cached/3` — a non-English library must not read English-cached
  titles.

  Relay-only, unlike its provider-agnostic siblings above: a TMDB collection is a
  relay concept, so a config naming any other provider type is rejected with an
  `:invalid_config` error rather than routed to the relay adapter under a cache
  key that names a provider which never served the response.

  ## Examples

      iex> Mydia.Metadata.fetch_collection_cached(config, 1241)
      {:ok, %Mydia.Metadata.Structs.Collection{name: "Harry Potter Collection", ...}}
  """
  def fetch_collection_cached(config, collection_id, opts \\ [])

  def fetch_collection_cached(%{type: :metadata_relay} = config, collection_id, opts) do
    alias Mydia.Metadata.Cache
    alias Mydia.Metadata.Provider.Relay

    language = Keyword.get(opts, :language, config_language(config))
    cache_key = "collection:metadata_relay:#{collection_id}:#{language}"

    Cache.fetch(
      cache_key,
      fn ->
        Relay.fetch_collection(config, collection_id, opts)
      end,
      ttl: :timer.hours(24)
    )
  end

  def fetch_collection_cached(%{type: type}, _collection_id, _opts) when is_atom(type) do
    {:error,
     Provider.Error.invalid_config(
       "Collections are only available through the metadata relay, got: #{inspect(type)}"
     )}
  end

  @doc """
  Fetches TMDB recommendations for a title, cached in ETS for 24 hours.

  Relay-only, for the same reason as `fetch_collection_cached/3`: no other
  provider type has an equivalent concept, so routing one to the relay adapter
  would cache a response under a key naming a provider that never served it.

  The language is part of the key so a non-English library never reads
  English-cached entries. The media type is part of the key because TMDB movie and
  TV ids overlap numerically.

  24 hours matches `fetch_collection_cached/3`. TMDB recommendations shift over
  weeks, and the relay caches upstream as well.

  ## Examples

      iex> config = Mydia.Metadata.default_relay_config()
      iex> Mydia.Metadata.fetch_recommendations_cached(config, "965150", media_type: :movie)
      {:ok, [%Mydia.Metadata.Structs.SearchResult{}]}
  """
  def fetch_recommendations_cached(config, provider_id, opts \\ [])

  def fetch_recommendations_cached(%{type: :metadata_relay} = config, provider_id, opts) do
    alias Mydia.Metadata.Cache
    alias Mydia.Metadata.Provider.Relay

    media_type = Keyword.get(opts, :media_type, :movie)
    language = Keyword.get(opts, :language, config_language(config))

    cache_key = "recommendations:metadata_relay:#{provider_id}:#{media_type}:#{language}"

    Cache.fetch(
      cache_key,
      fn -> Relay.fetch_recommendations(config, provider_id, opts) end,
      ttl: :timer.hours(24)
    )
  end

  def fetch_recommendations_cached(%{type: type}, _provider_id, _opts) when is_atom(type) do
    {:error,
     Provider.Error.invalid_config(
       "Recommendations are only available through the metadata relay, got: #{inspect(type)}"
     )}
  end

  @doc """
  Fetches images for a specific media item.

  ## Parameters
    - `config` - Provider configuration map
    - `provider_id` - Provider-specific ID for the media item
    - `opts` - Image fetch options

  ## Options
    * `:media_type` - Media type (`:movie` or `:tv_show`, default: `:movie`)
    * `:language` - Primary language for images
    * `:include_image_language` - Additional languages to include

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.fetch_images(config, "603", media_type: :movie)
      {:ok, %{posters: [...], backdrops: [...], logos: [...]}}
  """
  def fetch_images(%{type: type} = config, provider_id, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.fetch_images(config, provider_id, opts)
    end
  end

  @doc """
  Fetches season details with episode information for a TV show.

  ## Parameters
    - `config` - Provider configuration map
    - `provider_id` - Provider-specific ID for the TV show
    - `season_number` - Season number to fetch
    - `opts` - Season fetch options

  ## Options
    * `:language` - Language for results (default: "en-US")

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.fetch_season(config, "1396", 1)
      {:ok, %{season_number: 1, episodes: [...], ...}}
  """
  def fetch_season(%{type: type} = config, provider_id, season_number, opts \\ [])
      when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.fetch_season(config, provider_id, season_number, opts)
    end
  end

  @doc """
  Fetches season details with caching to reduce API calls.

  This is a cached wrapper around `fetch_season/4` that caches results
  for 24 hours to reduce redundant API calls.

  Results are cached by provider_id, season_number, and language.

  ## Parameters
    - `config` - Provider configuration map
    - `provider_id` - Provider-specific ID for the TV show
    - `season_number` - Season number to fetch
    - `opts` - Season fetch options

  ## Options
    * `:language` - Language for results (default: "en-US")

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.fetch_season_cached(config, "1396", 1)
      {:ok, %{season_number: 1, episodes: [...], ...}}
  """
  def fetch_season_cached(%{type: type} = config, provider_id, season_number, opts \\ [])
      when is_atom(type) do
    alias Mydia.Metadata.Cache

    # Default to the configured language so a non-English library does not read
    # the English library's cached season (see fetch_by_id_cached/3).
    language = Keyword.get(opts, :language, config_language(config))
    tvdb_season_id = Keyword.get(opts, :tvdb_season_id)
    cache_key = build_season_cache_key(provider_id, season_number, language, tvdb_season_id)

    # Cache for 24 hours
    Cache.fetch(
      cache_key,
      fn ->
        fetch_season(config, provider_id, season_number, opts)
      end,
      ttl: :timer.hours(24)
    )
  end

  @doc """
  Builds a deterministic cache key for season data.

  Used by `fetch_season_cached/4` and by callers that need to invalidate
  specific season cache entries.
  """
  def build_season_cache_key(
        provider_id,
        season_number,
        language \\ "en-US",
        tvdb_season_id \\ nil
      ) do
    "season:#{provider_id}:#{season_number}:#{language}:#{tvdb_season_id}"
  end

  @doc """
  Gets the metadata relay base URL.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay if not set.

  ## Examples

      iex> Mydia.Metadata.metadata_relay_url()
      "https://relay.mydia.dev"
  """
  def metadata_relay_url do
    Application.get_env(:mydia, :metadata_relay_url) ||
      System.get_env("METADATA_RELAY_URL", "https://relay.mydia.dev")
  end

  @doc """
  Gets the configured metadata language.

  The language is sent to TMDB/TVDB through the metadata-relay so titles,
  descriptions, and image translations come back in the user's preferred locale.
  Resolved through the standard 4-layer config precedence:
  `METADATA_LANGUAGE` env var → admin DB setting (`metadata.language`) → YAML
  config (`metadata.language`) → schema default (`"en-US"`).

  Accepts any value the underlying provider understands — typically an ISO 639-1
  code (`"de"`) or BCP 47 language tag (`"de-DE"`, `"pt-BR"`).

  ## Examples

      iex> Mydia.Metadata.metadata_language()
      "en-US"
  """
  def metadata_language do
    case Mydia.Settings.get_metadata_config() do
      %{language: lang} when is_binary(lang) and lang != "" -> lang
      _ -> @default_language
    end
  end

  # Reads the language carried on a provider config (populated from
  # metadata_language/0 via default_relay_config/0), falling back to "en-US"
  # for bare configs. Used to default cache-key language so entries vary by the
  # configured language. Mirrors Relay's private config_language/1.
  defp config_language(config) do
    case config do
      %{options: %{language: lang}} when is_binary(lang) and lang != "" -> lang
      _ -> @default_language
    end
  end

  # Resources common to both movie and TV detail fetches.
  @shared_append_to_response [
    "credits",
    "images",
    "videos",
    "keywords",
    "recommendations",
    "external_ids"
  ]

  @doc """
  The `append_to_response` list for a full-detail metadata fetch (initial
  match, refresh, provider switch), scoped to `media_type`.

  Movies and TV shows have different valid TMDB append resources — movies
  carry certification under `release_dates`, TV shows under
  `content_ratings` — and TMDB validates `append_to_response` per endpoint,
  so mixing the two risks breaking the fetch for one media type. Extending
  either list is the only way to pull in another TMDB resource —
  metadata-relay forwards `append_to_response` straight through to TMDB with
  no allowlist, so nothing outside this module needs to change to add one.
  """
  @spec default_append_to_response(:movie | :tv_show) :: [String.t()]
  def default_append_to_response(:movie) do
    @shared_append_to_response ++ ["release_dates"]
  end

  def default_append_to_response(:tv_show) do
    @shared_append_to_response ++ ["content_ratings"]
  end

  @doc """
  Gets the default metadata relay configuration.

  This provides a ready-to-use configuration for the metadata-relay service
  that doesn't require an API key.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay at relay.mydia.dev if not set. The metadata
  language can be configured via the METADATA_LANGUAGE environment variable.

  ## Examples

      iex> Mydia.Metadata.default_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://relay.mydia.dev",
        options: %{language: "en-US", include_adult: false, timeout: 30_000}
      }
  """
  def default_relay_config do
    %{
      type: :metadata_relay,
      base_url: metadata_relay_url(),
      options: %{
        language: metadata_language(),
        include_adult: false,
        timeout: 30_000
      }
    }
  end

  @doc """
  Gets the default TVDB relay configuration.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay at relay.mydia.dev if not set. The metadata
  language can be configured via the METADATA_LANGUAGE environment variable.

  ## Examples

      iex> Mydia.Metadata.default_tvdb_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://relay.mydia.dev",
        options: %{language: "en-US", timeout: 30_000}
      }
  """
  def default_tvdb_relay_config do
    %{
      type: :metadata_relay,
      base_url: metadata_relay_url(),
      options: %{
        language: metadata_language(),
        timeout: 30_000
      }
    }
  end

  @doc """
  Fetches trending media for a specific media type.

  ## Parameters
    - `config` - Provider configuration map
    - `opts` - Trending options (see `Mydia.Metadata.Provider` for available options)

  ## Options
    * `:media_type` - Media type to fetch (`:movie` or `:tv_show`, required)
    * `:language` - Language for results (default: "en-US")
    * `:page` - Page number for pagination (default: 1)

  ## Examples

      iex> config = %{type: :metadata_relay, base_url: "https://relay.mydia.dev"}
      iex> Mydia.Metadata.fetch_trending(config, media_type: :movie)
      {:ok, [%{provider_id: "603", title: "Trending Movie", ...}]}
  """
  def fetch_trending(%{type: type} = config, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.fetch_trending(config, opts)
    end
  end

  @doc """
  Fetches trending movies using the default relay configuration.

  This is a convenience function that uses the default metadata relay config.
  Results are cached for 1 hour to reduce API calls.

  ## Examples

      iex> Mydia.Metadata.trending_movies()
      {:ok, [%{provider_id: "603", title: "Trending Movie", ...}]}
  """
  def trending_movies do
    alias Mydia.Metadata.Cache

    Cache.fetch("trending_movies", fn ->
      fetch_trending(default_relay_config(), media_type: :movie)
    end)
  end

  @doc """
  Fetches trending TV shows using the default relay configuration.

  This is a convenience function that uses the default metadata relay config.
  Results are cached for 1 hour to reduce API calls.

  ## Examples

      iex> Mydia.Metadata.trending_tv_shows()
      {:ok, [%{provider_id: "1396", title: "Trending Show", ...}]}
  """
  def trending_tv_shows do
    alias Mydia.Metadata.Cache

    Cache.fetch("trending_tv_shows", fn ->
      fetch_trending(default_relay_config(), media_type: :tv_show)
    end)
  end

  @doc """
  Fetches a curated list (trending, popular, upcoming, etc.) with caching.

  ## Parameters
    - `list_type` - One of :trending, :popular, :upcoming, :now_playing, :on_the_air, :airing_today
    - `opts` - Options including :media_type, :page, :language

  ## Examples

      iex> Mydia.Metadata.fetch_curated_list(:popular, media_type: :movie, page: 1)
      {:ok, %{results: [...], page: 1, total_pages: 500}}
  """
  def fetch_curated_list(list_type, opts \\ []) do
    alias Mydia.Metadata.Cache
    alias Mydia.Metadata.Provider.Relay

    media_type = Keyword.get(opts, :media_type, :movie)
    page = Keyword.get(opts, :page, 1)

    cache_key = "curated:#{list_type}:#{media_type}:#{page}"

    Cache.fetch(
      cache_key,
      fn ->
        Relay.fetch_curated(default_relay_config(), list_type, opts)
      end,
      ttl: :timer.minutes(30)
    )
  end

  @doc """
  Discovers media with filters (genres, year, language, rating, sort) with caching.

  ## Parameters
    - `media_type` - :movie or :tv_show
    - `opts` - Filter options including :genres, :year, :original_language, :min_rating, :sort_by, :page

  ## Examples

      iex> Mydia.Metadata.discover(:movie, genres: "28,12", year: 2024, sort_by: "vote_average.desc")
      {:ok, %{results: [...], page: 1, total_pages: 100}}
  """
  def discover(media_type, opts \\ []) do
    alias Mydia.Metadata.Cache
    alias Mydia.Metadata.Provider.Relay

    page = Keyword.get(opts, :page, 1)
    genres = Keyword.get(opts, :genres)
    original_language = Keyword.get(opts, :original_language)
    year = Keyword.get(opts, :year)
    min_rating = Keyword.get(opts, :min_rating)
    sort_by = Keyword.get(opts, :sort_by, "popularity.desc")

    cache_key =
      "discover:#{media_type}:#{genres}:#{original_language}:#{year}:#{min_rating}:#{sort_by}:#{page}"

    Cache.fetch(
      cache_key,
      fn ->
        Relay.fetch_discover(default_relay_config(), media_type, opts)
      end,
      ttl: :timer.minutes(15)
    )
  end

  @doc """
  Fetches genre list for a media type with caching (24hr TTL).

  ## Parameters
    - `media_type` - :movie or :tv_show

  ## Examples

      iex> Mydia.Metadata.genres(:movie)
      {:ok, [%{id: 28, name: "Action"}, %{id: 12, name: "Adventure"}, ...]}
  """
  def genres(media_type) do
    alias Mydia.Metadata.Cache
    alias Mydia.Metadata.Provider.Relay

    cache_key = "genres:#{media_type}"

    Cache.fetch(
      cache_key,
      fn ->
        Relay.fetch_genres(default_relay_config(), media_type)
      end,
      ttl: :timer.hours(24)
    )
  end
end
