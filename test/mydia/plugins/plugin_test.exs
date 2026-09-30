defmodule Mydia.Plugins.PluginTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin

  test "from_manifest/2 carries the 1.5 instance fields" do
    {:ok, manifest} =
      Manifest.parse(%{
        "slug" => "plex",
        "name" => "Plex",
        "version" => "1.0.0",
        "multi_instance" => true,
        "category" => "media_server",
        "setup" => true,
        "capabilities" => %{"events:subscribe" => ["media_file.imported"]}
      })

    plugin = Plugin.from_manifest(manifest)
    assert plugin.multi_instance
    assert plugin.category == "media_server"
    assert plugin.setup
  end
end
