defmodule Mydia.MediaServer.Plex.EndpointProbeConnectionsTest do
  # Synchronous on purpose. `:plex_endpoint_cache` is a single global ETS table
  # shared with every other Plex endpoint test, so the "does not populate the
  # cache" assertion below would otherwise read entries a concurrent test wrote,
  # and this module's `invalidate_all/0` would wipe that test's cache mid-run.
  # ExUnit runs sync modules only after the async ones finish, which makes both
  # hazards impossible rather than merely unlikely.
  use ExUnit.Case, async: false

  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Plex.Endpoint

  setup do
    bypass = Bypass.open()
    # Clear on the way in as well as out: entries left by an earlier module
    # would otherwise be attributed to this one.
    Endpoint.invalidate_all()
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
