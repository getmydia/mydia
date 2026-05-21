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

      config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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

  alias Mydia.Metadata.Provider

  @doc """
  Registers all known metadata provider adapters with the registry.

  This function is called automatically during application startup.
  Adapters must be registered before they can be used.

  ## Registered Providers

  Currently supported providers:
    - `:metadata_relay` - metadata-relay.dorninger.co proxy service (recommended)
    - `:tmdb` - The Movie Database API (when implemented)
    - `:tvdb` - The TV Database API (when implemented)
  """
  def register_providers do
    Logger.info("Registering metadata provider adapters...")

    # Register metadata-relay as the primary provider
    Provider.Registry.register(:metadata_relay, Mydia.Metadata.Provider.Relay)
    Provider.Registry.register(:music_relay, Mydia.Metadata.Provider.MusicRelay)
    Provider.Registry.register(:open_library, Mydia.Metadata.Provider.OpenLibrary)

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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
      iex> Mydia.Metadata.search_cached(config, "The Matrix", media_type: :movie, year: 1999)
      {:ok, [%{provider_id: "603", title: "The Matrix", ...}]}
  """
  def search_cached(%{type: type} = config, query, opts \\ []) when is_atom(type) do
    alias Mydia.Metadata.Cache

    # Build cache key including all relevant search parameters
    media_type = Keyword.get(opts, :media_type)
    year = Keyword.get(opts, :year)
    language = Keyword.get(opts, :language, "en-US")
    page = Keyword.get(opts, :page, 1)

    # Create a stable cache key from query and options
    cache_key = "search:#{query}:#{media_type}:#{year}:#{language}:#{page}"

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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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
    language = Keyword.get(opts, :language, "en-US")

    cache_key = "fetch_by_id:#{provider_id}:#{media_type}:#{language}:#{append}"

    Cache.fetch(
      cache_key,
      fn ->
        fetch_by_id(config, provider_id, opts)
      end,
      ttl: :timer.hours(1)
    )
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co/tmdb"}
      iex> Mydia.Metadata.fetch_season_cached(config, "1396", 1)
      {:ok, %{season_number: 1, episodes: [...], ...}}
  """
  def fetch_season_cached(%{type: type} = config, provider_id, season_number, opts \\ [])
      when is_atom(type) do
    alias Mydia.Metadata.Cache

    language = Keyword.get(opts, :language, "en-US")
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
      _ -> "en-US"
    end
  end

  @doc """
  Gets the default metadata relay configuration.

  This provides a ready-to-use configuration for the metadata-relay service
  that doesn't require an API key.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay at https://relay.mydia.dev if not set. The
  metadata language can be configured via the METADATA_LANGUAGE environment
  variable.

  ## Examples

      iex> Mydia.Metadata.default_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://relay.mydia.dev",
        options: %{language: "en-US", include_adult: false}
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
  defaulting to the self-hosted relay at https://relay.mydia.dev if not set. The
  metadata language can be configured via the METADATA_LANGUAGE environment
  variable.

  ## Examples

      iex> Mydia.Metadata.default_tvdb_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://relay.mydia.dev",
        options: %{language: "en-US"}
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

      iex> config = %{type: :metadata_relay, base_url: "https://metadata-relay.dorninger.co"}
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

  @doc """
  Gets the default music relay configuration.
  """
  def default_music_relay_config do
    %{
      type: :music_relay,
      base_url: metadata_relay_url(),
      options: %{
        timeout: 30_000
      }
    }
  end

  @doc """
  Gets the default book relay configuration.
  """
  def default_book_relay_config do
    %{
      type: :open_library,
      base_url: metadata_relay_url(),
      options: %{
        timeout: 30_000
      }
    }
  end

  # Music Metadata Functions

  def search_artist(%{type: type} = config, query, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.search_artist(config, query, opts)
    end
  end

  def search_release(%{type: type} = config, query, opts \\ []) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.search_release(config, query, opts)
    end
  end

  def get_artist(%{type: type} = config, mbid) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.get_artist(config, mbid)
    end
  end

  def get_release(%{type: type} = config, mbid) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.get_release(config, mbid)
    end
  end

  def get_release_group(%{type: type} = config, mbid) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.get_release_group(config, mbid)
    end
  end

  def get_recording(%{type: type} = config, mbid) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.get_recording(config, mbid)
    end
  end

  def get_cover_art(%{type: type} = config, mbid) when is_atom(type) do
    with {:ok, provider} <- Provider.Registry.get_provider(type) do
      provider.get_cover_art(config, mbid)
    end
  end
end
