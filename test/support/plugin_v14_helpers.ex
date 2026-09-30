defmodule Mydia.PluginV14Helpers do
  @moduledoc """
  Starts the checked-in 1.4 contract fixture component under a slug, with a
  plugin config row, a registry entry and a running pool, the way the Simkl
  integration test starts its guest. Registers `on_exit` cleanup, so call it
  from a test or `setup` block.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @fixture "test/support/fixtures/plugins/host_v14_fixture.wasm"

  @grants %{
    "net:http" => ["auth.example.invalid"],
    "state:kv" => [],
    "users:connections" => []
  }

  @settings_schema [
    %{"key" => "url", "label" => "Server URL", "type" => "url", "grants_host" => true},
    %{"key" => "suggest_user_id", "label" => "Suggested user", "type" => "string"}
  ]

  @spec start_v14_fixture!(keyword()) :: String.t()
  def start_v14_fixture!(opts \\ []) do
    slug = Keyword.get(opts, :slug, "v14_fixture")

    manifest = %{
      "slug" => slug,
      "name" => "V14 Fixture",
      "version" => "1.0.0",
      "multi_instance" => true,
      "category" => "media_server",
      "setup" => true,
      "settings_schema" => @settings_schema,
      "capabilities" => %{"events:subscribe" => ["media_file.imported"]}
    }

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: "V14 Fixture",
        version: "1.0.0",
        source_url: "test",
        manifest: manifest,
        settings: %{},
        granted_capabilities: @grants,
        enabled: true
      })

    {:ok, _} =
      Registry.register(slug, %Plugin{
        slug: slug,
        name: "V14 Fixture",
        granted_capabilities: @grants,
        enabled: true,
        setup: true,
        multi_instance: true,
        category: "media_server"
      })

    imports =
      HostFunctions.imports_for(slug,
        allow_private: true,
        resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
      )

    {:ok, _pid} = Host.start_plugin(slug, File.read!(@fixture), imports: imports)

    on_exit(fn ->
      Host.stop_plugin(slug)
      Registry.unregister(slug)
    end)

    slug
  end
end
