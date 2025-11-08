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
  Gets the default metadata relay configuration.

  This provides a ready-to-use configuration for the metadata-relay service
  that doesn't require an API key.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay on Fly.io if not set.

  ## Examples

      iex> Mydia.Metadata.default_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://metadata-relay.fly.dev",
        options: %{language: "en-US", include_adult: false}
      }
  """
  def default_relay_config do
    base_url = System.get_env("METADATA_RELAY_URL", "https://metadata-relay.fly.dev")

    %{
      type: :metadata_relay,
      base_url: base_url,
      options: %{
        language: "en-US",
        include_adult: false,
        timeout: 30_000
      }
    }
  end

  @doc """
  Gets the default TVDB relay configuration.

  The base URL can be configured via the METADATA_RELAY_URL environment variable,
  defaulting to the self-hosted relay on Fly.io if not set.

  ## Examples

      iex> Mydia.Metadata.default_tvdb_relay_config()
      %{
        type: :metadata_relay,
        base_url: "https://metadata-relay.fly.dev",
        options: %{language: "en-US"}
      }
  """
  def default_tvdb_relay_config do
    base_url = System.get_env("METADATA_RELAY_URL", "https://metadata-relay.fly.dev")

    %{
      type: :metadata_relay,
      base_url: base_url,
      options: %{
        language: "en-US",
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
end
