defmodule Mydia.Downloads.BuiltIn.GluetunClientTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.GluetunClient

  setup do
    bypass = Bypass.open()
    %{bypass: bypass, req: GluetunClient.new("http://localhost:#{bypass.port}", "k3y")}
  end

  test "vpn_status sends the API key", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/vpn/status", fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-api-key") == ["k3y"]
      Plug.Conn.resp(conn, 200, ~s({"status":"running"}))
    end)

    assert GluetunClient.vpn_status(req) == {:ok, "running"}
  end

  test "public_ip", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/publicip/ip", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"public_ip":"203.0.113.9","country":"Nowhere"}))
    end)

    assert GluetunClient.public_ip(req) == {:ok, "203.0.113.9"}
  end

  test "forwarded_port is 0 when none", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/portforward", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"port":0}))
    end)

    assert GluetunClient.forwarded_port(req) == {:ok, 0}
  end

  test "an unreachable server is an error", %{bypass: bypass, req: req} do
    Bypass.down(bypass)
    assert {:error, _} = GluetunClient.vpn_status(req)
  end
end
