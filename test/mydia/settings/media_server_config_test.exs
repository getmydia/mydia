defmodule Mydia.Settings.MediaServerConfigTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.MediaServerConfig

  describe "changeset/2 connection resilience fields" do
    test "casts the full connection candidate list" do
      connections = [
        %{"uri" => "https://a.plex.direct:32400", "local" => true, "relay" => false},
        %{"uri" => "https://b.plex.direct:32400", "local" => false, "relay" => false}
      ]

      changeset =
        MediaServerConfig.changeset(%MediaServerConfig{}, %{
          name: "Storage",
          type: :plex,
          url: "https://a.plex.direct:32400",
          machine_identifier: "cf3ab3f4",
          connections: connections
        })

      assert changeset.valid?
      assert get_change(changeset, :machine_identifier) == "cf3ab3f4"
      assert get_change(changeset, :connections) == connections
    end

    test "records an auth error with its timestamp" do
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        MediaServerConfig.changeset(%MediaServerConfig{}, %{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          last_auth_error: "HTTP 401",
          last_auth_error_at: at
        })

      assert changeset.valid?
      assert get_change(changeset, :last_auth_error) == "HTTP 401"
    end

    test "connections defaults to an empty list" do
      assert %MediaServerConfig{}.connections == []
    end
  end
end
