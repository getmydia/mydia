defmodule Mydia.MediaServer.NoNativePlexTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.MediaServerConfig

  test "the native Plex modules are gone" do
    for mod <- [
          Mydia.MediaServer.Client.Plex,
          Mydia.MediaServer.Plex.Endpoint,
          Mydia.MediaServer.Plex.Home,
          Mydia.MediaServer.Plex.Selection,
          Mydia.MediaServer.PlexOAuth,
          Mydia.WatchSync.Providers.Plex
        ] do
      refute Code.ensure_loaded?(mod), "#{inspect(mod)} should have been deleted"
    end
  end

  test "a media server config can no longer be Plex" do
    changeset =
      MediaServerConfig.changeset(%MediaServerConfig{}, %{
        name: "Glass Orchard Server",
        type: :plex,
        url: "http://192.168.1.20:32400"
      })

    refute changeset.valid?
    assert {_, opts} = changeset.errors[:type]
    assert opts[:validation] == :inclusion
    assert opts[:enum] == ["jellyfin"]
  end
end
