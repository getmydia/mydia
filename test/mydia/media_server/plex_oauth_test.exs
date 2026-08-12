defmodule Mydia.MediaServer.PlexOAuthTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.PlexOAuth

  describe "parse_server/1" do
    test "keeps every connection, the machine identifier, and the access token" do
      resource = %{
        "name" => "Storage",
        "clientIdentifier" => "cf3ab3f4",
        "provides" => "server",
        "owned" => true,
        "presence" => true,
        "accessToken" => "resource-token",
        "connections" => [
          %{
            "uri" => "https://local.plex.direct:32400",
            "address" => "10.1.1.5",
            "port" => 32_400,
            "protocol" => "https",
            "local" => true,
            "relay" => false
          },
          %{
            "uri" => "https://remote.plex.direct:32400",
            "address" => "1.2.3.4",
            "port" => 32_400,
            "protocol" => "https",
            "local" => false,
            "relay" => false
          }
        ]
      }

      server = PlexOAuth.parse_server(resource)

      assert server.machine_identifier == "cf3ab3f4"
      assert server.access_token == "resource-token"
      # The whole list survives. An earlier revision kept only one ranked pick,
      # which froze an address that later became unroutable.
      assert length(server.connections) == 2
    end
  end
end
