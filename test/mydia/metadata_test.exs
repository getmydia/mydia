defmodule Mydia.MetadataTest do
  use ExUnit.Case, async: false

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider
  alias Mydia.Metadata.Structs.ImagesResponse

  # Mock provider for testing
  defmodule MockProvider do
    @behaviour Mydia.Metadata.Provider

    alias Mydia.Metadata.Structs.ImagesResponse

    @impl true
    def test_connection(_config), do: {:ok, %{status: "ok"}}

    @impl true
    def search(_config, _query, _opts), do: {:ok, []}

    @impl true
    def fetch_by_id(_config, _id, _opts), do: {:ok, %{}}

    @impl true
    def fetch_images(_config, _id, _opts),
      do: {:ok, ImagesResponse.new(%{posters: [], backdrops: [], logos: []})}

    @impl true
    def fetch_season(_config, _id, _season, _opts), do: {:ok, %{}}

    @impl true
    def fetch_trending(_config, opts) do
      # Simulate different responses for movies vs TV shows
      case Keyword.get(opts, :media_type) do
        :movie ->
          {:ok,
           [
             %{
               provider_id: "1",
               title: "Trending Movie 1",
               media_type: "movie",
               vote_average: 8.5
             },
             %{
               provider_id: "2",
               title: "Trending Movie 2",
               media_type: "movie",
               vote_average: 8.0
             }
           ]}

        :tv_show ->
          {:ok,
           [
             %{
               provider_id: "101",
               name: "Trending Show 1",
               media_type: "tv",
               vote_average: 9.0
             },
             %{
               provider_id: "102",
               name: "Trending Show 2",
               media_type: "tv",
               vote_average: 8.7
             }
           ]}

        _ ->
          {:error, :invalid_media_type}
      end
    end
  end

  setup do
    # Clear cache and register mock provider
    Cache.clear()
    Provider.Registry.register(:metadata_relay, MockProvider)

    on_exit(fn ->
      Cache.clear()
      Provider.Registry.clear()
    end)

    :ok
  end

  describe "trending_movies/0" do
    test "fetches trending movies from provider" do
      # Re-register providers to ensure mock is used
      Provider.Registry.register(:metadata_relay, MockProvider)

      assert {:ok, movies} = Metadata.trending_movies()
      assert is_list(movies)
      assert length(movies) == 2
      assert %{title: "Trending Movie 1"} = Enum.at(movies, 0)
    end

    test "caches trending movies results" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # First call should fetch from provider and cache
      assert {:ok, movies1} = Metadata.trending_movies()

      # Verify value is in cache
      assert {:ok, cached_movies} = Cache.get("trending_movies")
      assert cached_movies == movies1

      # Second call should return cached value
      assert {:ok, movies2} = Metadata.trending_movies()
      assert movies2 == movies1
    end

    test "returns cached value without calling provider" do
      # Pre-populate cache with specific data
      cached_data = [
        %{provider_id: "999", title: "Cached Movie", media_type: "movie"}
      ]

      Cache.put("trending_movies", cached_data)

      # Call should return cached data
      assert {:ok, movies} = Metadata.trending_movies()
      assert movies == cached_data
    end

    test "respects cache TTL" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Put with very short TTL (1ms)
      Cache.put("trending_movies", [%{title: "Old Data"}], ttl: 1)

      # Wait for expiration
      Process.sleep(10)

      # Should fetch fresh data
      assert {:ok, movies} = Metadata.trending_movies()
      assert length(movies) == 2
      assert %{title: "Trending Movie 1"} = Enum.at(movies, 0)
    end

    test "uses default 1-hour TTL" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch and cache
      assert {:ok, _movies} = Metadata.trending_movies()

      # Verify cache entry exists and hasn't expired after short time
      Process.sleep(100)
      assert {:ok, _cached} = Cache.get("trending_movies")
    end
  end

  describe "trending_tv_shows/0" do
    test "fetches trending TV shows from provider" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      assert {:ok, shows} = Metadata.trending_tv_shows()
      assert is_list(shows)
      assert length(shows) == 2
      assert %{name: "Trending Show 1"} = Enum.at(shows, 0)
    end

    test "caches trending TV shows results" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # First call should fetch from provider and cache
      assert {:ok, shows1} = Metadata.trending_tv_shows()

      # Verify value is in cache
      assert {:ok, cached_shows} = Cache.get("trending_tv_shows")
      assert cached_shows == shows1

      # Second call should return cached value
      assert {:ok, shows2} = Metadata.trending_tv_shows()
      assert shows2 == shows1
    end

    test "returns cached value without calling provider" do
      # Pre-populate cache with specific data
      cached_data = [
        %{provider_id: "888", name: "Cached Show", media_type: "tv"}
      ]

      Cache.put("trending_tv_shows", cached_data)

      # Call should return cached data
      assert {:ok, shows} = Metadata.trending_tv_shows()
      assert shows == cached_data
    end

    test "respects cache TTL" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Put with very short TTL (1ms)
      Cache.put("trending_tv_shows", [%{name: "Old Show Data"}], ttl: 1)

      # Wait for expiration
      Process.sleep(10)

      # Should fetch fresh data
      assert {:ok, shows} = Metadata.trending_tv_shows()
      assert length(shows) == 2
      assert %{name: "Trending Show 1"} = Enum.at(shows, 0)
    end

    test "uses default 1-hour TTL" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch and cache
      assert {:ok, _shows} = Metadata.trending_tv_shows()

      # Verify cache entry exists and hasn't expired after short time
      Process.sleep(100)
      assert {:ok, _cached} = Cache.get("trending_tv_shows")
    end

    test "trending TV shows cache is independent from movies cache" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch both
      assert {:ok, movies} = Metadata.trending_movies()
      assert {:ok, shows} = Metadata.trending_tv_shows()

      # Verify they are different and independently cached
      refute movies == shows

      # Clear movies cache
      Cache.delete("trending_movies")

      # TV shows cache should still exist
      assert {:ok, _cached_shows} = Cache.get("trending_tv_shows")
      assert {:error, :not_found} = Cache.get("trending_movies")
    end
  end

  describe "cache invalidation" do
    test "can manually invalidate trending movies cache" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch and cache
      assert {:ok, _movies} = Metadata.trending_movies()
      assert {:ok, _cached} = Cache.get("trending_movies")

      # Invalidate cache
      Cache.delete("trending_movies")

      # Cache should be empty
      assert {:error, :not_found} = Cache.get("trending_movies")

      # Next call should fetch fresh data
      assert {:ok, movies} = Metadata.trending_movies()
      assert length(movies) == 2
    end

    test "can manually invalidate trending TV shows cache" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch and cache
      assert {:ok, _shows} = Metadata.trending_tv_shows()
      assert {:ok, _cached} = Cache.get("trending_tv_shows")

      # Invalidate cache
      Cache.delete("trending_tv_shows")

      # Cache should be empty
      assert {:error, :not_found} = Cache.get("trending_tv_shows")

      # Next call should fetch fresh data
      assert {:ok, shows} = Metadata.trending_tv_shows()
      assert length(shows) == 2
    end

    test "can clear all cache entries" do
      # Re-register mock provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Fetch both
      assert {:ok, _movies} = Metadata.trending_movies()
      assert {:ok, _shows} = Metadata.trending_tv_shows()

      # Verify both are cached
      assert {:ok, _} = Cache.get("trending_movies")
      assert {:ok, _} = Cache.get("trending_tv_shows")

      # Clear all cache
      Cache.clear()

      # Both should be gone
      assert {:error, :not_found} = Cache.get("trending_movies")
      assert {:error, :not_found} = Cache.get("trending_tv_shows")
    end
  end

  describe "error handling with cache" do
    defmodule ErrorProvider do
      @behaviour Mydia.Metadata.Provider

      @impl true
      def test_connection(_config), do: {:error, :connection_failed}

      @impl true
      def search(_config, _query, _opts), do: {:error, :api_error}

      @impl true
      def fetch_by_id(_config, _id, _opts), do: {:error, :not_found}

      @impl true
      def fetch_images(_config, _id, _opts), do: {:error, :api_error}

      @impl true
      def fetch_season(_config, _id, _season, _opts), do: {:error, :api_error}

      @impl true
      def fetch_trending(_config, _opts), do: {:error, :api_unavailable}
    end

    test "does not cache error results for movies" do
      Provider.Registry.register(:metadata_relay, ErrorProvider)

      # First call returns error
      assert {:error, :api_unavailable} = Metadata.trending_movies()

      # Verify error was not cached
      assert {:error, :not_found} = Cache.get("trending_movies")

      # Register working provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Next call should fetch successfully
      assert {:ok, movies} = Metadata.trending_movies()
      assert length(movies) == 2
    end

    test "does not cache error results for TV shows" do
      Provider.Registry.register(:metadata_relay, ErrorProvider)

      # First call returns error
      assert {:error, :api_unavailable} = Metadata.trending_tv_shows()

      # Verify error was not cached
      assert {:error, :not_found} = Cache.get("trending_tv_shows")

      # Register working provider
      Provider.Registry.register(:metadata_relay, MockProvider)

      # Next call should fetch successfully
      assert {:ok, shows} = Metadata.trending_tv_shows()
      assert length(shows) == 2
    end
  end

  describe "default_relay_config/0" do
    test "returns configuration with metadata_relay type" do
      config = Metadata.default_relay_config()

      assert config.type == :metadata_relay
      assert is_binary(config.base_url)
      assert is_map(config.options)
    end

    test "uses METADATA_RELAY_URL environment variable when set" do
      System.put_env("METADATA_RELAY_URL", "https://custom-relay.example.com")

      config = Metadata.default_relay_config()
      assert config.base_url == "https://custom-relay.example.com"

      System.delete_env("METADATA_RELAY_URL")
    end

    test "uses default URL when environment variable not set" do
      System.delete_env("METADATA_RELAY_URL")

      config = Metadata.default_relay_config()
      assert config.base_url == "https://metadata-relay.arsfeld.dev"
    end
  end
end
