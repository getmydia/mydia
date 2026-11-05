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

  test "forwarded_port reports a non-zero port", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/portforward", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"port":51820}))
    end)

    assert GluetunClient.forwarded_port(req) == {:ok, 51820}
  end

  test "a non-200 status is an error", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/vpn/status", fn conn ->
      Plug.Conn.resp(conn, 503, ~s({"error":"unavailable"}))
    end)

    assert GluetunClient.vpn_status(req) == {:error, {:http_status, 503}}
  end

  test "a raw JSON string with no content type is decoded", %{bypass: bypass, req: req} do
    Bypass.expect_once(bypass, "GET", "/v1/publicip/ip", fn conn ->
      conn
      |> Plug.Conn.delete_resp_header("content-type")
      |> Plug.Conn.resp(200, ~s({"public_ip":"203.0.113.9"}))
    end)

    assert GluetunClient.public_ip(req) == {:ok, "203.0.113.9"}
  end

  test "a decoded non-object body is an invalid response, not a crash", %{
    bypass: bypass,
    req: req
  } do
    Bypass.expect_once(bypass, "GET", "/v1/vpn/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s([1,2,3]))
    end)

    assert GluetunClient.vpn_status(req) == {:error, :invalid_json}
  end

  test "an unreachable server is an error", %{bypass: bypass, req: req} do
    Bypass.down(bypass)
    assert {:error, _} = GluetunClient.vpn_status(req)
  end
end
