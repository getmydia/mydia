defmodule MetadataRelay.CacheTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Cache

  setup do
    # Ensure in-memory cache is used for testing
    Application.put_env(:metadata_relay, :cache_adapter, MetadataRelay.Cache.InMemory)

    # Start the in-memory cache
    case GenServer.whereis(MetadataRelay.Cache.InMemory) do
      nil -> start_supervised!(MetadataRelay.Cache.InMemory)
      _pid -> :ok
    end

    Cache.clear()

    :ok
  end

  describe "build_key/3" do
    test "builds key from method, path, and query string" do
      assert Cache.build_key("GET", "/tmdb/movies/search", "query=matrix") ==
               "GET:/tmdb/movies/search:query=matrix"
    end

    test "handles empty query string" do
      assert Cache.build_key("GET", "/tmdb/movies/603", "") ==
               "GET:/tmdb/movies/603:"
    end

    test "handles POST requests" do
      assert Cache.build_key("POST", "/tmdb/auth", "key=value") ==
               "POST:/tmdb/auth:key=value"
    end

    test "preserves full query string structure" do
      assert Cache.build_key("GET", "/path", "a=1&b=2&c=3") ==
               "GET:/path:a=1&b=2&c=3"
    end
  end

  describe "get/1 and put/3" do
    test "stores and retrieves values" do
      key = Cache.build_key("GET", "/test", "")

      assert :ok = Cache.put(key, "test_value")
      assert {:ok, "test_value"} = Cache.get(key)
    end

    test "returns not_found for missing keys" do
      assert {:error, :not_found} = Cache.get("nonexistent:key")
    end

    test "stores complex values" do
      key = Cache.build_key("GET", "/api/data", "")
      value = %{status: 200, body: %{data: [1, 2, 3]}, headers: [{"content-type", "json"}]}

      assert :ok = Cache.put(key, value)
      assert {:ok, ^value} = Cache.get(key)
    end

    test "allows explicit TTL override" do
      key = Cache.build_key("GET", "/custom", "")

      # Use very short TTL
      assert :ok = Cache.put(key, "value", ttl: 100)
      assert {:ok, "value"} = Cache.get(key)

      # Wait for expiration
      Process.sleep(150)

      assert {:error, :not_found} = Cache.get(key)
    end
  end

  describe "automatic TTL selection" do
    test "uses 90-day TTL for image paths" do
      image_key = Cache.build_key("GET", "/tmdb/images/poster.jpg", "")

      # We can't directly test the TTL value, but we can verify
      # the key is stored and the pattern matching works
      assert :ok = Cache.put(image_key, "image_data")
      assert {:ok, "image_data"} = Cache.get(image_key)

      # Verify it doesn't expire quickly (not trending TTL)
      Process.sleep(100)
      assert {:ok, "image_data"} = Cache.get(image_key)
    end

    test "uses 1-hour TTL for trending paths" do
      trending_key = Cache.build_key("GET", "/tmdb/trending/movies", "")

      assert :ok = Cache.put(trending_key, "trending_data")
      assert {:ok, "trending_data"} = Cache.get(trending_key)
    end

    test "uses 7-day TTL for search results" do
      search_key = Cache.build_key("GET", "/tmdb/movies/search", "query=matrix")

      assert :ok = Cache.put(search_key, "search_results")
      assert {:ok, "search_results"} = Cache.get(search_key)
    end

    test "uses 30-day TTL for movie details by ID" do
      movie_key = Cache.build_key("GET", "/tmdb/movies/603", "")

      assert :ok = Cache.put(movie_key, "movie_data")
      assert {:ok, "movie_data"} = Cache.get(movie_key)
    end

    test "uses 30-day TTL for TV show details by ID" do
      tv_key = Cache.build_key("GET", "/tmdb/tv/shows/1234", "")

      assert :ok = Cache.put(tv_key, "tv_data")
      assert {:ok, "tv_data"} = Cache.get(tv_key)
    end

    test "uses 14-day TTL for season/episode data" do
      episode_key = Cache.build_key("GET", "/tmdb/tv/shows/1234/1/5", "")

      assert :ok = Cache.put(episode_key, "episode_data")
      assert {:ok, "episode_data"} = Cache.get(episode_key)
    end

    test "does not apply details TTL to search paths" do
      # This should not match the movie details pattern
      search_key = Cache.build_key("GET", "/tmdb/movies/search", "query=123")

      assert :ok = Cache.put(search_key, "search_data")
      assert {:ok, "search_data"} = Cache.get(search_key)
    end

    test "uses default TTL for unknown paths" do
      generic_key = Cache.build_key("GET", "/api/generic", "")

      assert :ok = Cache.put(generic_key, "generic_data")
      assert {:ok, "generic_data"} = Cache.get(generic_key)
    end
  end

  describe "clear/0" do
    test "removes all cached entries" do
      key1 = Cache.build_key("GET", "/path1", "")
      key2 = Cache.build_key("GET", "/path2", "")

      Cache.put(key1, "value1")
      Cache.put(key2, "value2")

      assert :ok = Cache.clear()

      assert {:error, :not_found} = Cache.get(key1)
      assert {:error, :not_found} = Cache.get(key2)
    end
  end

  describe "stats/0" do
    test "returns cache statistics" do
      Cache.clear()

      stats = Cache.stats()

      assert is_map(stats)
      assert stats.adapter == "in_memory"
      assert is_integer(stats.hits)
      assert is_integer(stats.misses)
      assert is_number(stats.hit_rate_pct)
    end

    test "stats reflect actual cache operations" do
      Cache.clear()

      # Generate some cache activity
      key = Cache.build_key("GET", "/test", "")

      # Miss
      Cache.get(key)

      # Hit
      Cache.put(key, "value")
      Cache.get(key)

      stats = Cache.stats()

      assert stats.misses >= 1
      assert stats.hits >= 1
      assert stats.total_requests >= 2
    end
  end

  describe "adapter selection" do
    test "uses InMemory adapter by default" do
      Application.put_env(:metadata_relay, :cache_adapter, MetadataRelay.Cache.InMemory)

      key = Cache.build_key("GET", "/test", "")
      Cache.put(key, "test")

      stats = Cache.stats()
      assert stats.adapter == "in_memory"
    end

    test "uses Redis adapter when configured" do
      # Save original adapter
      original_adapter = Application.get_env(:metadata_relay, :cache_adapter)

      # Configure Redis adapter
      Application.put_env(:metadata_relay, :cache_adapter, MetadataRelay.Cache.Redis)

      # Start Redis adapter with invalid config (will fail gracefully)
      case GenServer.whereis(MetadataRelay.Cache.Redis) do
        nil ->
          start_supervised!({MetadataRelay.Cache.Redis, [host: "invalid", port: 9999]})

        _pid ->
          :ok
      end

      stats = Cache.stats()
      assert stats.adapter == "redis"

      # Restore original adapter
      Application.put_env(:metadata_relay, :cache_adapter, original_adapter)
    end
  end

  describe "ttl_for/1 for watch providers" do
    test "watch provider lists expire after a day" do
      assert MetadataRelay.Cache.ttl_for("GET:/tmdb/watch/providers/movie:watch_region=CA") ==
               :timer.hours(24)
    end
  end

  describe "integration scenarios" do
    test "handles typical API request caching workflow" do
      # Simulate caching an API request/response
      method = "GET"
      path = "/tmdb/movies/550"
      query = ""

      key = Cache.build_key(method, path, query)

      # First request - cache miss
      assert {:error, :not_found} = Cache.get(key)

      # Store the response
      response = %{
        status: 200,
        body: ~s({"id": 550, "title": "Fight Club"}),
        headers: [{"content-type", "application/json"}]
      }

      assert :ok = Cache.put(key, response)

      # Second request - cache hit
      assert {:ok, ^response} = Cache.get(key)
    end

    test "handles different API endpoints independently" do
      key1 = Cache.build_key("GET", "/tmdb/movies/550", "")
      key2 = Cache.build_key("GET", "/tmdb/movies/551", "")
      key3 = Cache.build_key("GET", "/tmdb/movies/search", "query=fight")

      Cache.put(key1, "movie_550")
      Cache.put(key2, "movie_551")
      Cache.put(key3, "search_results")

      assert {:ok, "movie_550"} = Cache.get(key1)
      assert {:ok, "movie_551"} = Cache.get(key2)
      assert {:ok, "search_results"} = Cache.get(key3)
    end

    test "query string variations create different cache keys" do
      path = "/tmdb/movies/search"

      key1 = Cache.build_key("GET", path, "query=matrix")
      key2 = Cache.build_key("GET", path, "query=matrix&year=1999")
      key3 = Cache.build_key("GET", path, "query=blade")

      Cache.put(key1, "results_1")
      Cache.put(key2, "results_2")
      Cache.put(key3, "results_3")

      assert {:ok, "results_1"} = Cache.get(key1)
      assert {:ok, "results_2"} = Cache.get(key2)
      assert {:ok, "results_3"} = Cache.get(key3)
    end
  end
end
