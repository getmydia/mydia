defmodule Mydia.MediaServer.Client.PlexConnectionTest do
  @moduledoc """
  Bypass tests for Plex connection classification.

  The critical case is a server that answers `/identity` without auth but 401s
  on real endpoints. That is exactly the production state that made a dead
  token look healthy for eight months.
  """
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Client.Plex
  alias Mydia.MediaServer.Error
  alias Mydia.Settings.MediaServerConfig

  setup do
    bypass = Bypass.open()

    config = %MediaServerConfig{
      name: "Test",
      type: :plex,
      url: "http://127.0.0.1:#{bypass.port}",
      token: "some-token"
    }

    {:ok, bypass: bypass, config: config}
  end

  test "a server that answers /identity but 401s on real endpoints is an auth error",
       %{bypass: bypass, config: config} do
    # /identity needs no token on a real Plex server, so it must not be the probe.
    Bypass.stub(bypass, "GET", "/identity", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{"machineIdentifier":"abc"}}))
    end)

    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    assert {:error, %Error{kind: :auth}} = Plex.test_connection(config)
  end

  test "a reachable authenticated server is ok", %{bypass: bypass, config: config} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"MediaContainer":{"Directory":[]}}))
    end)

    assert :ok = Plex.test_connection(config)
  end

  test "an unreachable server is an unreachable error, not an auth error", %{config: config} do
    down = %{config | url: "http://127.0.0.1:1"}
    assert {:error, %Error{kind: :unreachable}} = Plex.test_connection(down)
  end

  test "a 403 classifies as auth", %{bypass: bypass, config: config} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 403, "")
    end)

    assert {:error, %Error{kind: :auth}} = Plex.test_connection(config)
  end

  test "a 500 classifies as unexpected", %{bypass: bypass, config: config} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 500, "")
    end)

    assert {:error, %Error{kind: :unexpected}} = Plex.test_connection(config)
  end

  describe "a server addressed by discovery rather than by url" do
    setup %{bypass: bypass, config: config} do
      discovered = %{
        config
        | url: nil,
          machine_identifier: "abc",
          connections: [%{"uri" => "http://127.0.0.1:#{bypass.port}"}]
      }

      {:ok, discovered: discovered}
    end

    test "is tested against its advertised connections", %{
      bypass: bypass,
      discovered: discovered
    } do
      # A Plex server connected through OAuth stores no url at all, so testing
      # `config.url` reported "URL is required" for a server that was reachable
      # the whole time.
      Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"MediaContainer":{"Directory":[]}}))
      end)

      assert :ok = Plex.test_connection(discovered)
    end

    test "reports a rejected token as an auth error", %{
      bypass: bypass,
      discovered: discovered
    } do
      Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      assert {:error, %Error{kind: :auth}} = Plex.test_connection(discovered)
    end

    test "reports an unreachable advertised address as unreachable", %{discovered: discovered} do
      dead = %{discovered | connections: [%{"uri" => "http://127.0.0.1:1"}]}

      assert {:error, %Error{kind: :unreachable}} = Plex.test_connection(dead)
    end

    test "an explicit url still wins over the advertised connections", %{
      bypass: bypass,
      discovered: discovered
    } do
      # Endpoint.resolve/1 treats a stored url as a manual operator override;
      # the test button has to agree with it or the two disagree about which
      # address was actually checked.
      Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
        Plug.Conn.resp(conn, 500, "")
      end)

      overridden = %{discovered | url: "http://127.0.0.1:#{bypass.port}"}

      assert {:error, %Error{kind: :unexpected}} = Plex.test_connection(overridden)
    end
  end

  test "a config with neither a url nor a connection still reports a missing url",
       %{config: config} do
    unaddressable = %{config | url: nil, connections: []}

    assert {:error, %Error{kind: :unexpected, detail: "URL is required"}} =
             Plex.test_connection(unaddressable)
  end
end
