defmodule Mydia.MediaServer.Plex.EndpointRediscoveryTest do
  use Mydia.DataCase, async: false

  alias Mydia.MediaServer.Plex.Endpoint
  alias Mydia.Settings

  setup do
    plex_tv = Bypass.open()
    server = Bypass.open()
    on_exit(fn -> Endpoint.invalidate_all() end)
    {:ok, plex_tv: plex_tv, server: server}
  end

  test "a moved server is rediscovered by machine identifier",
       %{plex_tv: plex_tv, server: server} do
    new_uri = "http://127.0.0.1:#{server.port}"

    Bypass.stub(plex_tv, "GET", "/api/v2/resources", fn conn ->
      body =
        Jason.encode!([
          %{
            "name" => "Storage",
            "clientIdentifier" => "cf3ab3f4",
            "provides" => "server",
            "owned" => true,
            "accessToken" => "fresh-token",
            "connections" => [%{"uri" => new_uri, "local" => true, "relay" => false}]
          }
        ])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, body)
    end)

    Bypass.stub(server, "GET", "/library/sections", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"MediaContainer":{}}))
    end)

    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Storage",
        type: :plex,
        token: "account-token",
        machine_identifier: "cf3ab3f4",
        # Only a dead address is stored, mirroring the production failure.
        connections: [%{"uri" => "http://127.0.0.1:1"}]
      })

    assert {:ok, updated} =
             Endpoint.rediscover(config,
               plex_tv_base: "http://127.0.0.1:#{plex_tv.port}/api/v2"
             )

    assert [%{"uri" => ^new_uri}] = updated.connections
    assert updated.server_access_token == "fresh-token"
    assert {:ok, ^new_uri} = Endpoint.resolve(updated)
  end
end
