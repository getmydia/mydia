defmodule Mydia.MediaServer.Plex.EndpointProbeConnectionsTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Plex.Endpoint

  setup do
    bypass = Bypass.open()
    on_exit(fn -> Endpoint.invalidate_all() end)
    {:ok, bypass: bypass}
  end

  test "returns the candidate that answers and ignores the dead one", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    live = "http://127.0.0.1:#{bypass.port}"

    assert {:ok, ^live} =
             Endpoint.probe_connections(
               [%{"uri" => "http://127.0.0.1:1"}, %{"uri" => live}],
               "tok"
             )
  end

  test "accepts atom-keyed connections, as parsed from plex.tv", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    live = "http://127.0.0.1:#{bypass.port}"

    assert {:ok, ^live} = Endpoint.probe_connections([%{uri: live}], "tok")
  end

  test "an empty candidate list is unreachable, not a crash" do
    assert {:error, %Error{kind: :unreachable}} = Endpoint.probe_connections([], "tok")
  end

  test "prefers an auth failure over a transport failure", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    rejecting = "http://127.0.0.1:#{bypass.port}"

    assert {:error, %Error{kind: :auth}} =
             Endpoint.probe_connections(
               [%{"uri" => "http://127.0.0.1:1"}, %{"uri" => rejecting}],
               "tok"
             )
  end

  test "all candidates dead reports unreachable" do
    assert {:error, %Error{kind: :unreachable}} =
             Endpoint.probe_connections(
               [%{"uri" => "http://127.0.0.1:1"}, %{"uri" => "http://127.0.0.1:2"}],
               "tok"
             )
  end

  test "does not populate the resolve cache" do
    # probe_connections/2 is used for unsaved configs that have no id to key on,
    # so it must stay cache-free.
    assert {:error, %Error{}} =
             Endpoint.probe_connections([%{"uri" => "http://127.0.0.1:1"}], "t")

    assert :ets.tab2list(:plex_endpoint_cache) == []
  end
end
