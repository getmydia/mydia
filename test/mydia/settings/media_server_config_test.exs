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

  describe "changeset/2 addressability" do
    test "a Plex config with discovery data needs no url" do
      changeset =
        MediaServerConfig.changeset(%MediaServerConfig{}, %{
          name: "Storage",
          type: :plex,
          machine_identifier: "cf3ab3f4",
          connections: [%{"uri" => "http://localhost:32400"}]
        })

      assert changeset.valid?
    end

    test "a Jellyfin config without a url is rejected" do
      # Jellyfin has no discovery, and Client.Jellyfin calls
      # String.trim_trailing(config.url, "/"), which raises on nil. Letting this
      # save would move the failure from validation to runtime.
      changeset = MediaServerConfig.changeset(%MediaServerConfig{}, %{name: "J", type: :jellyfin})

      refute changeset.valid?
      assert %{url: ["can't be blank"]} = errors_on(changeset)
    end

    test "a Plex config with neither url nor discovery data is rejected" do
      changeset = MediaServerConfig.changeset(%MediaServerConfig{}, %{name: "P", type: :plex})

      refute changeset.valid?
    end

    test "a blank url does not count as addressable" do
      changeset =
        MediaServerConfig.changeset(%MediaServerConfig{}, %{
          name: "J",
          type: :jellyfin,
          url: "   "
        })

      refute changeset.valid?
    end
  end

  describe "connections_refreshed_at" do
    test "is cast and round-trips through the database" do
      at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Refresh Stamp #{System.unique_integer([:positive])}",
          type: :plex,
          token: "tok",
          machine_identifier: "abc123",
          connections: [%{"uri" => "http://127.0.0.1:32400"}],
          connections_refreshed_at: at
        })

      assert config.connections_refreshed_at == at

      assert Mydia.Repo.get!(Mydia.Settings.MediaServerConfig, config.id).connections_refreshed_at ==
               at
    end

    test "defaults to nil when not provided" do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "No Stamp #{System.unique_integer([:positive])}",
          type: :plex,
          token: "tok",
          machine_identifier: "def456",
          connections: [%{"uri" => "http://127.0.0.1:32400"}]
        })

      assert is_nil(config.connections_refreshed_at)
    end
  end
end
