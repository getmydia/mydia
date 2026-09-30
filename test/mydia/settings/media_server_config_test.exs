defmodule Mydia.Settings.MediaServerConfigTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.MediaServerConfig

  describe "changeset/2 defaults" do
    test "connections defaults to an empty list" do
      assert %MediaServerConfig{}.connections == []
    end
  end

  describe "changeset/2 addressability" do
    test "a Jellyfin config without a url is rejected" do
      # Client.Jellyfin calls String.trim_trailing(config.url, "/"), which raises
      # on nil. Letting this save would move the failure from validation to
      # runtime.
      changeset = MediaServerConfig.changeset(%MediaServerConfig{}, %{name: "J", type: :jellyfin})

      refute changeset.valid?
      assert %{url: ["can't be blank"]} = errors_on(changeset)
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

    test "a Jellyfin config with a url is valid" do
      changeset =
        MediaServerConfig.changeset(%MediaServerConfig{}, %{
          name: "J",
          type: :jellyfin,
          url: "http://localhost:8096"
        })

      assert changeset.valid?
    end
  end
end
