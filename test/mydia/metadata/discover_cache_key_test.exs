defmodule Mydia.Metadata.DiscoverCacheKeyTest do
  # Mutates :metadata_relay_url and the shared metadata cache.
  use ExUnit.Case, async: false

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")
    Cache.clear()

    on_exit(fn ->
      Cache.clear()

      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    %{bypass: bypass}
  end

  test "two streaming services are cached separately", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:provider, conn.query_params["with_watch_providers"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    assert {:ok, _} = Metadata.discover(:movie, watch_region: "CA", with_watch_providers: "1")
    assert {:ok, _} = Metadata.discover(:movie, watch_region: "CA", with_watch_providers: "2")

    assert_receive {:provider, "1"}
    assert_receive {:provider, "2"}
  end

  test "two release windows are cached separately", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:gte, conn.query_params["release_date.gte"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    assert {:ok, _} = Metadata.discover(:movie, region: "CA", release_date_gte: "2026-01-01")
    assert {:ok, _} = Metadata.discover(:movie, region: "CA", release_date_gte: "2026-02-01")

    assert_receive {:gte, "2026-01-01"}
    assert_receive {:gte, "2026-02-01"}
  end
end
