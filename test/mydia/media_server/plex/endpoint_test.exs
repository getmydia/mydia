defmodule Mydia.MediaServer.Plex.EndpointTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Error
  alias Mydia.MediaServer.Plex.Endpoint
  alias Mydia.Settings.MediaServerConfig

  setup do
    bypass = Bypass.open()
    on_exit(fn -> Endpoint.invalidate_all() end)
    {:ok, bypass: bypass}
  end

  defp config(connections, opts \\ []) do
    %MediaServerConfig{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      name: "Test",
      type: :plex,
      token: "tok",
      url: Keyword.get(opts, :url),
      connections: connections
    }
  end

  test "picks the reachable candidate and skips the dead one", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    live = "http://127.0.0.1:#{bypass.port}"

    cfg =
      config([
        %{"uri" => "http://127.0.0.1:1"},
        %{"uri" => live}
      ])

    assert {:ok, ^live} = Endpoint.resolve(cfg)
  end

  test "an explicit url overrides discovery entirely", %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    manual = "http://127.0.0.1:#{bypass.port}"
    cfg = config([%{"uri" => "http://127.0.0.1:1"}], url: manual)

    assert {:ok, ^manual} = Endpoint.resolve(cfg)
  end

  test "all candidates dead returns unreachable" do
    cfg = config([%{"uri" => "http://127.0.0.1:1"}, %{"uri" => "http://127.0.0.1:2"}])
    assert {:error, %Error{kind: :unreachable}} = Endpoint.resolve(cfg)
  end

  test "an authenticating candidate that 401s surfaces as auth, not unreachable",
       %{bypass: bypass} do
    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 401, "")
    end)

    cfg = config([%{"uri" => "http://127.0.0.1:#{bypass.port}"}])
    assert {:error, %Error{kind: :auth}} = Endpoint.resolve(cfg)
  end

  test "the winner is cached and reused without re-probing", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    cfg = config([%{"uri" => "http://127.0.0.1:#{bypass.port}"}])

    assert {:ok, url} = Endpoint.resolve(cfg)
    assert {:ok, ^url} = Endpoint.resolve(cfg)

    assert Agent.get(counter, & &1) == 1
  end

  test "invalidate forces a re-probe", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "GET", "/library/sections", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    cfg = config([%{"uri" => "http://127.0.0.1:#{bypass.port}"}])

    assert {:ok, _} = Endpoint.resolve(cfg)
    Endpoint.invalidate(cfg)
    assert {:ok, _} = Endpoint.resolve(cfg)

    assert Agent.get(counter, & &1) == 2
  end
end
