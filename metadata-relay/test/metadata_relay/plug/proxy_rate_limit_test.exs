defmodule MetadataRelay.Plug.ProxyRateLimitTest do
  @moduledoc """
  Regression tests for T-263: the ~30 TMDB/TVDB proxy routes had no rate
  limit at all ahead of them. `MetadataRelay.Plug.Cache` sits in the
  pipeline but is trivially defeated per request by a throwaway query
  param, forcing a genuine, fully-credentialed call to the relay's shared
  TMDB_API_KEY/TVDB_API_KEY on every request.
  """

  use ExUnit.Case, async: false

  alias MetadataRelay.Router
  alias MetadataRelay.Test.TMDBHelpers

  @moduletag :capture_log

  setup do
    System.put_env("TMDB_API_KEY", "test_api_key_12345")
    MetadataRelay.Cache.clear()

    case GenServer.whereis(MetadataRelay.RateLimiter) do
      nil -> start_supervised!(MetadataRelay.RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)

    TMDBHelpers.set_tmdb_adapter(fn request ->
      {request, Req.Response.new(status: 200, body: %{"results" => []})}
    end)

    on_exit(fn ->
      TMDBHelpers.clear_tmdb_adapter()
      System.delete_env("TMDB_API_KEY")
      # Don't leak this suite's rate-limit entries into whichever test file
      # runs next -- several of these tests deliberately exhaust the
      # "proxy:127.0.0.1" bucket.
      :ets.delete_all_objects(:rate_limiter)
    end)

    :ok
  end

  # Cache-busts on every request, exactly as an attacker abusing T-263 would:
  # a fresh throwaway query param defeats MetadataRelay.Plug.Cache and forces
  # a genuine upstream call every time.
  defp cache_busting_request(i) do
    Plug.Test.conn(:get, "/tmdb/movies/search?query=batman&_=#{i}") |> Router.call([])
  end

  test "cache-busted requests to a TMDB proxy route are rate limited" do
    statuses = for i <- 1..300, do: cache_busting_request(i).status
    assert Enum.all?(statuses, &(&1 == 200))

    conn = cache_busting_request(301)

    assert conn.status == 429
    assert ["60"] = Plug.Conn.get_resp_header(conn, "retry-after")
  end

  test "the limit is shared across different TMDB/TVDB routes, not per-route" do
    for i <- 1..300 do
      conn = Plug.Test.conn(:get, "/tmdb/movies/popular?_=#{i}") |> Router.call([])
      assert conn.status == 200
    end

    # A 301st request against a *different* proxied route from the same
    # caller must still be limited -- an attacker cannot reset their budget
    # by spreading requests across the ~30 routes.
    conn = Plug.Test.conn(:get, "/tmdb/movies/search?query=batman&_=extra") |> Router.call([])

    assert conn.status == 429
  end

  test "a cache hit does not count against the limit" do
    # Warm the cache with one request.
    warm = Plug.Test.conn(:get, "/tmdb/movies/search?query=cached") |> Router.call([])
    assert warm.status == 200

    # Repeating the identical request 300+ times is served entirely from
    # cache and must never trip the proxy rate limit.
    statuses =
      for _ <- 1..350 do
        conn = Plug.Test.conn(:get, "/tmdb/movies/search?query=cached") |> Router.call([])
        conn.status
      end

    assert Enum.all?(statuses, &(&1 == 200))
  end

  test "routes outside the proxy set (e.g. /health) are unaffected" do
    for _ <- 1..305 do
      conn =
        Plug.Test.conn(:get, "/tmdb/movies/search?_=#{System.unique_integer()}")
        |> Router.call([])

      _ = conn
    end

    conn = Plug.Test.conn(:get, "/health") |> Router.call([])
    assert conn.status == 200
  end
end
