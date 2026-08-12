defmodule Mydia.MediaServer.Plex.EndpointStalenessTest do
  use Mydia.DataCase, async: false

  alias Mydia.MediaServer.Plex.Endpoint
  alias Mydia.Settings

  setup do
    plex_tv = Bypass.open()
    server = Bypass.open()
    on_exit(fn -> Endpoint.invalidate_all() end)

    Bypass.stub(server, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    test_pid = self()

    Bypass.stub(plex_tv, "GET", "/api/v2/resources", fn conn ->
      send(test_pid, :refreshed)

      body =
        Jason.encode!([
          %{
            "name" => "Storage",
            "clientIdentifier" => "machine-1",
            "provides" => "server",
            "owned" => true,
            "accessToken" => "fresh-token",
            "connections" => [
              %{"uri" => "http://127.0.0.1:#{server.port}", "local" => true, "relay" => false}
            ]
          }
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    {:ok, plex_tv: plex_tv, server: server}
  end

  defp create_config(server, opts) do
    Settings.create_media_server_config(%{
      name: "Storage #{System.unique_integer([:positive])}",
      type: :plex,
      token: "account-token",
      machine_identifier: Keyword.get(opts, :machine_identifier, "machine-1"),
      connections: [%{"uri" => "http://127.0.0.1:#{server.port}"}],
      connections_refreshed_at: Keyword.get(opts, :refreshed_at)
    })
  end

  defp opts(plex_tv), do: [plex_tv_base: "http://127.0.0.1:#{plex_tv.port}/api/v2"]

  defp hours_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 3600, :second) |> DateTime.truncate(:second)

  test "a nil timestamp triggers a refresh", %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: nil)

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    assert_receive :refreshed, 2_000
  end

  test "a timestamp older than six hours triggers a refresh",
       %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: hours_ago(7))

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    assert_receive :refreshed, 2_000
  end

  test "a fresh timestamp triggers nothing", %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: hours_ago(1))

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    refute_receive :refreshed, 500
  end

  test "a config with no machine_identifier triggers nothing",
       %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: nil, machine_identifier: nil)

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    refute_receive :refreshed, 500
  end

  test "a manual url override never triggers a refresh", %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: nil)

    {:ok, config} =
      Settings.update_media_server_config(config, %{url: "http://127.0.0.1:#{server.port}"})

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    refute_receive :refreshed, 500
  end

  test "concurrent resolves refresh only once", %{plex_tv: plex_tv, server: server} do
    test_pid = self()

    # Re-stub so the refresh holds its claim for the whole burst. Without this
    # the first refresh can finish and release before the last resolve runs,
    # which would let a second refresh start and make the test flaky.
    Bypass.stub(plex_tv, "GET", "/api/v2/resources", fn conn ->
      send(test_pid, :refreshed)
      Process.sleep(300)

      body =
        Jason.encode!([
          %{
            "name" => "Storage",
            "clientIdentifier" => "machine-1",
            "provides" => "server",
            "owned" => true,
            "accessToken" => "fresh-token",
            "connections" => [
              %{"uri" => "http://127.0.0.1:#{server.port}", "local" => true, "relay" => false}
            ]
          }
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    {:ok, config} = create_config(server, refreshed_at: nil)

    1..5
    |> Enum.map(fn _ -> Task.async(fn -> Endpoint.resolve(config, opts(plex_tv)) end) end)
    |> Enum.each(&Task.await(&1, 5_000))

    assert_receive :refreshed, 2_000
    refute_receive :refreshed, 800
  end

  test "the refresh stamps connections_refreshed_at", %{plex_tv: plex_tv, server: server} do
    {:ok, config} = create_config(server, refreshed_at: nil)

    assert {:ok, _url} = Endpoint.resolve(config, opts(plex_tv))
    assert_receive :refreshed, 2_000

    # The HTTP handler fires before the background task writes, so poll rather
    # than sleeping on a guessed duration.
    assert eventually(fn ->
             not is_nil(Settings.get_media_server_config!(config.id).connections_refreshed_at)
           end)
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, attempts - 1)
    end
  end
end
