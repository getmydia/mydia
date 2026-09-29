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

  test "two origin countries are cached separately", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:origin, conn.query_params["with_origin_country"]})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    assert {:ok, _} = Metadata.discover(:movie, origin_country: "CA")
    assert {:ok, _} = Metadata.discover(:movie, origin_country: "FR")

    assert_receive {:origin, "CA"}
    assert_receive {:origin, "FR"}
  end
end
