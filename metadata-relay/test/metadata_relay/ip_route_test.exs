defmodule MetadataRelay.IpRouteTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Router

  test "GET /ip returns the caller's address and is never cached" do
    conn =
      Plug.Test.conn(:get, "/ip")
      |> Map.put(:remote_ip, {198, 51, 100, 7})
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"ip" => "198.51.100.7"}
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "each caller gets its own address, not a cached copy of the first" do
    first = get_from({198, 51, 100, 7})
    second = get_from({203, 0, 113, 9})

    assert Jason.decode!(first.resp_body) == %{"ip" => "198.51.100.7"}
    assert Jason.decode!(second.resp_body) == %{"ip" => "203.0.113.9"}
  end

  defp get_from(remote_ip) do
    Plug.Test.conn(:get, "/ip")
    |> Map.put(:remote_ip, remote_ip)
    |> Router.call(Router.init([]))
  end
end
