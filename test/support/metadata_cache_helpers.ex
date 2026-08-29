defmodule Mydia.MetadataCacheHelpers do
  @moduledoc """
  Warms the shared metadata ETS cache through the real fetch path, with the
  relay response served by Bypass.

  None of these cache keys include the base URL, so a LiveView reading through
  its own default relay config gets these entries back with no outbound
  request. Left unwarmed, a detail-page test reaches the live relay and its
  result depends on the network being up and on whatever TMDB currently says
  about the id (#530).

  Every helper registers an `on_exit` that deletes the key it wrote. The cache
  is ETS-backed and process-independent, so an entry left behind leaks into
  every later test sharing that key.

  These were private helpers duplicated across `section_order_test.exs` and
  `franchise_section_test.exs`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  # Provider ids are offset past this floor rather than taken raw from
  # System.unique_integer/1, which hands out small positive integers. Those
  # collide two ways: with real TMDB ids, so any lookup a test forgets to warm
  # would reach the live relay, and with the many hardcoded ids elsewhere in
  # the suite, which share this same ETS cache and its keys. Real TMDB ids are
  # seven digits, and no fixture in the suite reaches nine.
  @provider_id_floor 900_000_000

  @doc """
  A provider id guaranteed not to collide with a real TMDB id or with a
  hardcoded id elsewhere in the suite.
  """
  def unique_provider_id, do: @provider_id_floor + System.unique_integer([:positive])

  @doc """
  Populates the recommendations cache for `tmdb_id` with `results`.

  `results` are raw TMDB result maps with string keys, for example
  `%{"id" => 123, "title" => "X", "release_date" => "2005-01-01"}`.
  """
  def warm_recommendations_cache(tmdb_id, media_type, results) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete(
        "recommendations:#{relay.type}:#{tmdb_id}:#{media_type}:#{relay.options.language}"
      )
    end)

    path =
      if media_type == :tv_show, do: "/tmdb/tv/shows/#{tmdb_id}", else: "/tmdb/movies/#{tmdb_id}"

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      body = %{
        "id" => tmdb_id,
        "title" => "Source",
        "recommendations" => %{
          "page" => 1,
          "results" => results,
          "total_pages" => 1,
          "total_results" => length(results)
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _results} =
      Metadata.fetch_recommendations_cached(config, to_string(tmdb_id), media_type: media_type)

    :ok
  end

  @doc """
  Populates the movie-details cache for `tmdb_id` with a collection-less payload.

  A movie whose metadata carries no collection_id sends
  `Franchises.resolve_collection_id/2` down a movie-details lookup with its own
  cache key, separate from the recommendations one. Warming it this way
  resolves that lookup to `:none` offline.
  """
  def warm_movie_details_cache(tmdb_id) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    # Mirrors the key fetch_by_id_cached/3 builds for these opts: no
    # append_to_response, so that segment is empty, and a nil season order
    # normalises to "official".
    on_exit(fn ->
      Cache.delete(
        "fetch_by_id:#{relay.type}:#{tmdb_id}:movie:#{relay.options.language}::official"
      )
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body = %{"id" => tmdb_id, "title" => "Source", "belongs_to_collection" => nil}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _details} = Metadata.fetch_by_id_cached(config, to_string(tmdb_id), media_type: :movie)

    :ok
  end

  @doc """
  Populates the TMDB collection cache behind the franchise strip.

  `parts` are raw TMDB result maps with string keys.
  """
  def warm_collection_cache(collection_id, parts) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete("collection:#{relay.type}:#{collection_id}:#{relay.options.language}")
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      body = %{"id" => collection_id, "name" => "Test Collection", "parts" => parts}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _collection} = Metadata.fetch_collection_cached(config, collection_id)

    :ok
  end

  @doc """
  Populates both cached entry points to the TMDB trending list for
  `media_type` (`:movie` or `:tv_show`) with `results`.

  `Mydia.Metadata.trending_movies/0`/`trending_tv_shows/0` (used by
  `DashboardLive`) and `Mydia.Metadata.fetch_curated_list/2` called with
  `:trending` (used by `DiscoverLive`'s default category) build the exact
  same `/tmdb/movies|tv/trending` request but land in two different cache
  keys, so both need warming or one of the two LiveViews still escapes.

  Unlike `fetch_by_id_cached/3` and friends, neither cached function accepts
  a config override, so this swaps `metadata_relay_url` for the duration of
  the call instead of building a throwaway config struct.
  """
  def warm_trending_cache(media_type, results) do
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    trending_key = if media_type == :tv_show, do: "trending_tv_shows", else: "trending_movies"
    curated_key = "curated:trending:#{media_type}:1"

    on_exit(fn ->
      Cache.delete(trending_key)
      Cache.delete(curated_key)
    end)

    path = if media_type == :tv_show, do: "/tmdb/tv/trending", else: "/tmdb/movies/trending"

    Bypass.expect(bypass, "GET", path, fn conn ->
      body = %{
        "page" => 1,
        "total_pages" => 1,
        "total_results" => length(results),
        "results" => results
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _results} =
      if media_type == :tv_show do
        Metadata.trending_tv_shows()
      else
        Metadata.trending_movies()
      end

    {:ok, _curated} = Metadata.fetch_curated_list(:trending, media_type: media_type, page: 1)

    case previous_metadata_relay_url do
      nil -> Application.delete_env(:mydia, :metadata_relay_url)
      value -> Application.put_env(:mydia, :metadata_relay_url, value)
    end

    :ok
  end

  @doc """
  Populates the TMDB genre-list cache for `media_type` (`:movie` or
  `:tv_show`) with `genres` (raw TMDB genre maps, e.g.
  `%{"id" => 28, "name" => "Action"}`).

  `Mydia.Metadata.genres/1` (used by `DiscoverLive`) does not accept a config
  override, so this swaps `metadata_relay_url` for the duration of the call,
  same as `warm_trending_cache/2`.
  """
  def warm_genre_cache(media_type, genres) do
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn -> Cache.delete("genres:#{media_type}") end)

    path = if media_type == :tv_show, do: "/tmdb/genre/tv", else: "/tmdb/genre/movie"

    Bypass.expect(bypass, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"genres" => genres}))
    end)

    {:ok, _genres} = Metadata.genres(media_type)

    case previous_metadata_relay_url do
      nil -> Application.delete_env(:mydia, :metadata_relay_url)
      value -> Application.put_env(:mydia, :metadata_relay_url, value)
    end

    :ok
  end

  @doc """
  Populates the movie search cache for `query` with `results`.

  `results` are raw TMDB result maps with string keys, matching
  `warm_recommendations_cache/3`. `opts` accepts `:year`, since both
  `Mydia.Library.MetadataMatcher.search_external_movie/3` (the library
  scanner) and callers of `Mydia.Metadata.search_cached/3` in general search
  with the parsed release year when one is known, and the year rides in the
  cache key.

  Unlike `fetch_recommendations_cached/3`, `search_cached/3` takes a
  `config` argument directly, so this follows the throwaway-config shape the
  other helpers above use rather than the env-swap `warm_trending_cache/2`
  and `warm_genre_cache/2` need.
  """
  def warm_movie_search_cache(query, opts, results) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    year = Keyword.get(opts, :year)

    # Mirrors the key search_cached/3 builds for these opts: no :provider or
    # :language override, so provider defaults to the config type and
    # language to the config's own.
    on_exit(fn ->
      Cache.delete("search:#{relay.type}:#{query}:movie:#{year}:#{relay.options.language}:1")
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/movies/search", fn conn ->
      body = %{
        "page" => 1,
        "total_pages" => 1,
        "total_results" => length(results),
        "results" => results
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    search_opts = if year, do: [media_type: :movie, year: year], else: [media_type: :movie]

    {:ok, _results} = Metadata.search_cached(config, query, search_opts)

    :ok
  end
end
