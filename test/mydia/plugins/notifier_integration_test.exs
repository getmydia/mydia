defmodule Mydia.Plugins.NotifierIntegrationTest do
  # async: false — installs/activates the real bundled notifier under the
  # app-wide registries.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "webhook-notifier"

  setup do
    Registry.clear()

    # Plugin lifecycle calls Plugins.reload/0, which replaces the global
    # :runtime_config — restore it so the pollution doesn't outlive the test.
    # Delete (not put nil) when it was unset: readers rely on get_env's default.
    original_runtime = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:mydia, :runtime_config, original_runtime)
      else
        Application.delete_env(:mydia, :runtime_config)
      end

      # `Plugins.register_plugins/0` activates *every* enabled row, so a test
      # here also starts the other shipped bundle (simkl_sync). Stop each
      # running pool before clearing the descriptors: a leaked pool is silently
      # reused by the next test's `Host.start_plugin/3` (an already-started slug
      # returns the existing process), which would run it with this test's
      # imports and settings.
      Enum.each(Registry.list(), &Host.stop_plugin(&1.slug))
      Host.stop_plugin(@slug)
      Registry.clear()
    end)

    :ok
  end

  test "R17: the bundled notifier is approved and activated through generic plugin plumbing" do
    assert :ok = Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug(@slug)
    assert config.enabled
    assert config.granted_capabilities == config.manifest["capabilities"]
    assert config.settings["delivery"] == "durable"
    # No bytes are copied into the DB — they resolve from the filesystem.
    assert config.wasm_module == nil
    assert config.integrity_hash == nil
    refute Plugins.needs_reapproval?(config)

    # The ordinary registration pass activates the enabled row as a durable
    # plugin, so the dispatcher routes its events through the Oban delivery
    # worker (U10) — no notifier-specific route or LiveView.
    assert :ok = Plugins.register_plugins()
    assert {:ok, descriptor} = Registry.lookup(@slug)
    assert descriptor.delivery == :durable
    assert descriptor.events == ["media_item.added", "download.completed"]
    assert Host.running?(@slug)
  end

  test "ensure_bundled does not trust a same-slug non-bundled plugin" do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Webhook Notifier",
        version: "0.9.0",
        granted_capabilities: %{"net:http" => ["discord.com"]},
        settings: %{"webhook_url" => "https://discord.com/api/webhooks/x"}
      })

    assert :ok = Plugins.ensure_bundled()

    # A row that is not source_url == "bundled" is third-party: discovery must
    # leave every field — provenance, grant, runtime state, settings, version —
    # exactly as it was.
    config = Settings.get_plugin_config_by_slug(@slug)
    assert config.source_url == nil
    assert config.granted_capabilities == %{"net:http" => ["discord.com"]}
    assert config.enabled == false
    assert config.settings["webhook_url"] == "https://discord.com/api/webhooks/x"
    assert config.version == "0.9.0"
  end

  test "ensure_bundled reconciles stale DB bytes on a pre-existing bundled row" do
    # Simulate an install that ran the old copy-into-DB seeding: a bundled row
    # carrying wasm bytes + an integrity hash in the DB.
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Webhook Notifier",
        version: "1.0.0",
        source_url: "bundled",
        wasm_module: "STALE-BYTES",
        integrity_hash: "deadbeef",
        granted_capabilities: %{"net:http" => ["discord.com"]},
        enabled: true,
        settings: %{"delivery" => "durable"}
      })

    assert :ok = Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug(@slug)
    # Stale bytes nulled so the resolver falls through to the filesystem.
    assert config.wasm_module == nil
    assert config.integrity_hash == nil
    # The grant is replaced with the shipped manifest's exact effective set.
    assert config.granted_capabilities == %{
             "events:subscribe" => ["media_item.added", "download.completed"],
             "net:http" => ["discord.com"],
             "data:read" => ["media_item"]
           }

    assert config.enabled == true
    assert config.settings["delivery"] == "durable"
  end

  test "ensure_bundled never clobbers a non-bundled (index) plugin's DB bytes" do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "an-index-plugin",
        name: "An Index Plugin",
        version: "1.0.0",
        source_url: "https://plugins.example.com/an-index-plugin.wasm",
        wasm_module: "INDEX-BYTES",
        integrity_hash: "abc123",
        enabled: true
      })

    assert :ok = Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug("an-index-plugin")
    # Reconcile only touches source_url == "bundled" rows.
    assert config.wasm_module == "INDEX-BYTES"
    assert config.integrity_hash == "abc123"
  end
end
