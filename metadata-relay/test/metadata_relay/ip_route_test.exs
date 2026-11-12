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

  test "prefers cf-connecting-ip over the Traefik peer behind Cloudflare" do
    conn =
      Plug.Test.conn(:get, "/ip")
      |> Map.put(:remote_ip, {10, 42, 0, 7})
      |> Plug.Conn.put_req_header("cf-connecting-ip", "203.0.113.50")
      |> Router.call(Router.init([]))

    assert Jason.decode!(conn.resp_body) == %{"ip" => "203.0.113.50"}
  end

  test "a blank cf-connecting-ip falls back to the resolved peer address" do
    conn =
      Plug.Test.conn(:get, "/ip")
      |> Map.put(:remote_ip, {198, 51, 100, 7})
      |> Plug.Conn.put_req_header("cf-connecting-ip", "   ")
      |> Router.call(Router.init([]))

    assert Jason.decode!(conn.resp_body) == %{"ip" => "198.51.100.7"}
  end

  test "a cf-connecting-ip that is not an IP falls back to the resolved peer address" do
    conn =
      Plug.Test.conn(:get, "/ip")
      |> Map.put(:remote_ip, {198, 51, 100, 7})
      |> Plug.Conn.put_req_header("cf-connecting-ip", "not-an-ip")
      |> Router.call(Router.init([]))

    assert Jason.decode!(conn.resp_body) == %{"ip" => "198.51.100.7"}
  end

  defp get_from(remote_ip) do
    Plug.Test.conn(:get, "/ip")
    |> Map.put(:remote_ip, remote_ip)
    |> Router.call(Router.init([]))
  end
end
