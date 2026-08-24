defmodule MetadataRelay.Cache do
  @moduledoc """
  Cache facade with pluggable backends (in-memory or Redis).

  Provides intelligent caching with TTL and size limits to reduce
  external API calls and prevent rate limiting.

  ## Cache Configuration

  The cache backend is selected at startup based on the REDIS_URL environment variable:
  - If REDIS_URL is set: Uses Redis for persistent, distributed caching
  - Otherwise: Falls back to in-memory ETS caching

  ## TTL Configuration

  - Movie/TV details by ID: 30 days TTL
  - Images: 90 days TTL (images never change)
  - Season/episode data: 14 days TTL
  - Search results: 7 days TTL
  - Trending: 1 hour TTL
  - Default: 24 hours TTL

  ## Cache Keys

  Cache keys are generated from:
    method:path:query_string

  Example: "GET:/tmdb/movies/search:query=matrix&year=1999"
  """

  # TTL values in milliseconds - aggressive caching for better hit rates
  @metadata_ttl :timer.hours(24 * 30)
  @images_ttl :timer.hours(24 * 90)
  @trending_ttl :timer.hours(1)
  @search_ttl :timer.hours(24 * 7)
  @details_ttl :timer.hours(24 * 30)
  @season_ttl :timer.hours(24 * 14)

  @doc """
  Builds a cache key from request method, path, and query string.

  ## Examples

      iex> Cache.build_key("GET", "/tmdb/movies/search", "query=matrix")
      "GET:/tmdb/movies/search:query=matrix"

      iex> Cache.build_key("GET", "/tmdb/movies/603", "")
      "GET:/tmdb/movies/603:"
  """
  def build_key(method, path, query_string) do
    "#{method}:#{path}:#{query_string}"
  end

  @doc """
  Gets a value from the cache.

  Returns `{:ok, value}` if found, `{:error, :not_found}` if not.
  """
  def get(key) do
    adapter().get(key)
  end

  @doc """
  Puts a value in the cache with appropriate TTL.

  TTL is automatically determined based on the key path unless provided in opts:
  - Images: 90 days
  - Trending: 1 hour
  - Search results: 7 days
  - Movie/TV details by ID: 30 days
  - Season/episode data: 14 days
  - Default: 30 days
  """
  def put(key, value, opts \\ []) do
    ttl = determine_ttl(key, opts)
    adapter().put(key, value, ttl)
  end

  @doc """
  Clears all entries from the cache.
  """
  def clear do
    adapter().clear()
  end

  @doc """
  Gets cache statistics.

  Returns a map with cache metrics including:
  - adapter: which cache backend is being used
  - hits: number of cache hits
  - misses: number of cache misses
  - hit_rate_pct: percentage of requests served from cache
  - (additional metrics vary by adapter)
  """
  def stats do
    adapter().stats()
  end

  ## Private Functions

  defp adapter do
    case Application.get_env(:metadata_relay, :cache_adapter) do
      MetadataRelay.Cache.Redis -> MetadataRelay.Cache.Redis
      _ -> MetadataRelay.Cache.InMemory
    end
  end

  defp determine_ttl(key, opts) do
    case Keyword.get(opts, :ttl) do
      nil -> auto_ttl(key)
      ttl -> ttl
    end
  end

  defp auto_ttl(key) do
    cond do
      # Images never change at a given path - longest TTL
      String.contains?(key, "/images") or String.contains?(key, "/music/cover/") ->
        @images_ttl

      # Trending data changes frequently - keep fresh
      String.contains?(key, "/trending") ->
        @trending_ttl

      # Search results - moderate caching
      String.contains?(key, "/search") ->
        @search_ttl

      # Specific movie/TV show details by ID - very stable data
      String.match?(key, ~r{/(movies|tv/shows)/\d+:(?!search)}) ->
        @details_ttl

      # Music details
      String.match?(key, ~r{/music/(artist|release|release-group|recording)/}) ->
        @details_ttl

      # Season/episode data - stable once aired
      String.contains?(key, "/tv/shows/") and String.match?(key, ~r{/\d+/\d+:}) ->
        @season_ttl

      # Default for other endpoints
      true ->
        @metadata_ttl
    end
  end
end
