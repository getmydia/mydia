defmodule MetadataRelay.Cache do
  @moduledoc """
  In-memory cache wrapper using ETS.

  Provides intelligent caching with TTL and size limits to reduce
  external API calls and prevent rate limiting.

  ## Cache Configuration

  - Movie/TV details by ID: 30 days TTL
  - Images: 90 days TTL (images never change)
  - Season/episode data: 14 days TTL
  - Search results: 7 days TTL
  - Trending: 1 hour TTL
  - Max entries: 20,000 (~160MB, LRU eviction)

  ## Cache Keys

  Cache keys are generated from:
    method:path:query_string

  Example: "GET:/tmdb/movies/search:query=matrix&year=1999"
  """

  alias MetadataRelay.CacheServer

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
    CacheServer.get(key)
  end

  @doc """
  Puts a value in the cache with appropriate TTL.

  TTL is automatically determined based on the path:
  - Images: 7 days
  - Trending: 1 hour
  - Everything else: 24 hours
  """
  def put(key, value, opts \\ []) do
    CacheServer.put(key, value, opts)
  end

  @doc """
  Clears all entries from the cache.
  """
  def clear do
    CacheServer.clear()
  end

  @doc """
  Gets cache statistics.

  Returns a map with cache metrics including:
  - size: current number of cached entries
  - memory_mb: memory usage in megabytes
  - hits: number of cache hits
  - misses: number of cache misses
  - hit_rate_pct: percentage of requests served from cache
  """
  def stats do
    CacheServer.stats()
  end
end
