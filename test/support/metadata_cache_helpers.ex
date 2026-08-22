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
end
