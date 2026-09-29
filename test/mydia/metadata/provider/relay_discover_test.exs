defmodule Mydia.Metadata.Provider.RelayDiscoverTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp capture_query(bypass, path) do
    test_pid = self()

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:query, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)
  end

  for {media_type, path} <- [movie: "/tmdb/movies/discover", tv_show: "/tmdb/tv/discover"] do
    test "#{media_type}: sends with_origin_country when origin_country is given",
         %{bypass: bypass, config: config} do
      capture_query(bypass, unquote(path))

      assert {:ok, _} = Relay.fetch_discover(config, unquote(media_type), origin_country: "CA")
      assert_receive {:query, %{"with_origin_country" => "CA"}}
    end

    test "#{media_type}: omits with_origin_country otherwise",
         %{bypass: bypass, config: config} do
      capture_query(bypass, unquote(path))

      assert {:ok, _} = Relay.fetch_discover(config, unquote(media_type), [])
      assert_receive {:query, params}
      refute Map.has_key?(params, "with_origin_country")
    end
  end
end
