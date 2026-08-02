defmodule Mydia.PluginsTest do
  # async: false — activation starts real pools under the app-wide PoolRegistry
  # and registers descriptors in the app-wide Plugins.Registry.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Index.Entry
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  # A prebuilt wasm32-wasip2 component implementing the mydia:plugin@1.0.0
  # contract. The host runs the component model, and WAT cannot express
  # components, so a core-wasm `(module ...)` fixture fails to instantiate
  # (surfaced as a :host_version "incompatible plugin contract" error). These
  # tests only exercise the install/activation lifecycle — none invoke the
  # guest — so any conforming component that instantiates works; reuse the
  # checked-in host_test fixture (see test/support/fixtures/plugins/).
  @guest_fixture Path.join([
                   __DIR__,
                   "..",
                   "support",
                   "fixtures",
                   "plugins",
                   "host_test_fixture.wasm"
                 ])

  defp guest_wasm, do: File.read!(@guest_fixture)

  defp manifest!(overrides \\ %{}) do
    base = %{
      "slug" => "webhook-notifier",
      "name" => "Webhook Notifier",
      "version" => "1.0.0",
      "capabilities" => %{
        "events:subscribe" => ["media_item.added"],
        "net:http" => ["discord.com"]
      }
    }

    {:ok, manifest} = Manifest.parse(Map.merge(base, overrides))
    manifest
  end

  defp entry(bypass, manifest, wasm) do
    %Entry{
      slug: manifest.slug,
      name: manifest.name,
      version: manifest.version,
      package_url: "http://allowed.test:#{bypass.port}/pkg.wasm",
      integrity: "sha256:#{:crypto.hash(:sha256, wasm) |> Base.encode16(case: :lower)}",
      manifest: manifest
    }
  end

  defp serve_package(bypass, wasm) do
    Bypass.stub(bypass, "GET", "/pkg.wasm", fn conn -> Plug.Conn.resp(conn, 200, wasm) end)
  end

  defp gate_opts, do: [allow_private: true, resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end]

  setup do
    Registry.clear()

    # Lifecycle functions call Plugins.reload/0, which replaces the global
    # :runtime_config with a snapshot computed from this test's sandboxed DB
    # and current env — restore it so the pollution doesn't outlive the test.
    # Delete (not put nil) when it was unset: readers rely on get_env's default.
    original_runtime = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:mydia, :runtime_config, original_runtime)
      else
        Application.delete_env(:mydia, :runtime_config)
      end

      Enum.each(Registry.list(), &Host.stop_plugin(&1.slug))
      Registry.clear()
    end)

    {:ok, bypass: Bypass.open()}
  end

  describe "install/2 and approve/2 (AE1, R7, deny-by-default)" do
    test "installing without grants does not activate; approving then activates with exactly the declared grants",
         %{bypass: bypass} do
      wasm = guest_wasm()
      manifest = manifest!()
      serve_package(bypass, wasm)

      # Install without approving any capability.
      assert {:ok, :inactive} =
               Plugins.install(entry(bypass, manifest, wasm), [grants: %{}] ++ gate_opts())

      refute Registry.registered?("webhook-notifier")
      refute Host.running?("webhook-notifier")
      assert Settings.get_plugin_config_by_slug("webhook-notifier").enabled == false

      # Approve: grants the full declared set and activates.
      assert {:ok, descriptor} = Plugins.approve("webhook-notifier")
      assert descriptor.granted_capabilities == manifest.capabilities
      assert Registry.registered?("webhook-notifier")
      assert Host.running?("webhook-notifier")
    end

    test "installing with the default (full) approval activates immediately", %{bypass: bypass} do
      wasm = guest_wasm()
      manifest = manifest!()
      serve_package(bypass, wasm)

      assert {:ok, descriptor} = Plugins.install(entry(bypass, manifest, wasm), gate_opts())
      assert descriptor.enabled
      assert descriptor.granted_capabilities["net:http"] == ["discord.com"]
      assert Host.running?("webhook-notifier")
    end

    test "a tampered package is rejected before anything is persisted", %{bypass: bypass} do
      wasm = guest_wasm()
      manifest = manifest!()
      serve_package(bypass, wasm)
      bad = %{entry(bypass, manifest, wasm) | integrity: "sha256:deadbeef"}

      assert {:error, %{type: :integrity_mismatch}} = Plugins.install(bad, gate_opts())
      assert Settings.get_plugin_config_by_slug("webhook-notifier") == nil
    end
  end

  describe "revoke/1 and remove/1 (R8, R14)" do
    setup %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)
      {:ok, _} = Plugins.install(entry(bypass, manifest!(), wasm), gate_opts())
      :ok
    end

    test "revoke clears grants and deactivates, keeping the config" do
      assert Host.running?("webhook-notifier")
      assert {:ok, :revoked} = Plugins.revoke("webhook-notifier")

      refute Registry.registered?("webhook-notifier")
      refute Host.running?("webhook-notifier")

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.enabled == false
      assert config.granted_capabilities == %{}
    end

    test "remove deactivates and deletes the config" do
      assert {:ok, :removed} = Plugins.remove("webhook-notifier")
      refute Registry.registered?("webhook-notifier")
      refute Host.running?("webhook-notifier")
      assert Settings.get_plugin_config_by_slug("webhook-notifier") == nil
    end

    test "set_enabled toggles activation" do
      assert {:ok, :disabled} = Plugins.set_enabled("webhook-notifier", false)
      refute Host.running?("webhook-notifier")

      assert {:ok, _} = Plugins.set_enabled("webhook-notifier", true)
      assert Host.running?("webhook-notifier")
    end
  end

  describe "update_settings/2 host-granting recomputation (KTD1, R2)" do
    defp schema_manifest do
      manifest!(%{
        "settings_schema" => [
          %{"key" => "webhook_url", "type" => "url", "grants_host" => true},
          %{"key" => "backup_url", "type" => "url", "grants_host" => true}
        ]
      })
    end

    defp granted_hosts(slug) do
      Settings.get_plugin_config_by_slug(slug).granted_capabilities["net:http"]
    end

    setup %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)
      {:ok, _} = Plugins.install(entry(bypass, schema_manifest(), wasm), gate_opts())
      :ok
    end

    test "configuring a host-granting url adds its host to the effective grant" do
      assert {:ok, _} =
               Plugins.update_settings("webhook-notifier", %{
                 "webhook_url" => "https://ntfy.example.com/mydia"
               })

      hosts = granted_hosts("webhook-notifier")
      assert "ntfy.example.com" in hosts
      assert "discord.com" in hosts
    end

    test "changing the url drops the previous host (full replacement)" do
      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{"webhook_url" => "https://a.example.com/x"})

      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{"webhook_url" => "https://b.example.com/x"})

      hosts = granted_hosts("webhook-notifier")
      assert "b.example.com" in hosts
      refute "a.example.com" in hosts
    end

    test "blank or unparseable url derives no host and keeps static hosts" do
      {:ok, _} = Plugins.update_settings("webhook-notifier", %{"webhook_url" => ""})
      assert granted_hosts("webhook-notifier") == ["discord.com"]
    end

    test "multiple host-granting fields union their hosts" do
      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{
          "webhook_url" => "https://one.example.com/x",
          "backup_url" => "https://two.example.com/y"
        })

      hosts = granted_hosts("webhook-notifier")
      assert "one.example.com" in hosts
      assert "two.example.com" in hosts
    end

    test "the live registry descriptor reflects the new host without a pool restart" do
      assert Host.running?("webhook-notifier")

      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{
          "webhook_url" => "https://ntfy.example.com/mydia"
        })

      {:ok, descriptor} = Registry.lookup("webhook-notifier")
      assert "ntfy.example.com" in descriptor.granted_capabilities["net:http"]
      assert Host.running?("webhook-notifier")
    end
  end

  describe "update_settings/2 deny-by-default (R2, R3)" do
    test "does not grant net:http for an unapproved plugin", %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)

      {:ok, :inactive} =
        Plugins.install(entry(bypass, schema_manifest(), wasm), [grants: %{}] ++ gate_opts())

      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{
          "webhook_url" => "https://ntfy.example.com/mydia"
        })

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["webhook_url"] == "https://ntfy.example.com/mydia"
      refute Map.has_key?(config.granted_capabilities, "net:http")
    end
  end

  describe "manifest revisions vs. grants (R5, deny-by-default)" do
    # A revision is exactly what `refresh_bundled_manifest/2` does: re-store the
    # declared manifest, never touch `granted_capabilities`.
    defp revise!(config, capabilities) do
      manifest = Map.put(config.manifest, "capabilities", capabilities)
      {:ok, revised} = Settings.update_plugin_config(config, %{manifest: manifest})
      revised
    end

    defp seed_installed!(capabilities, opts \\ []) do
      granted = Keyword.get(opts, :granted, capabilities)

      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: "webhook-notifier",
          name: "Webhook Notifier",
          version: "1.0.0",
          manifest: %{
            "slug" => "webhook-notifier",
            "name" => "Webhook Notifier",
            "version" => "1.0.0",
            "capabilities" => capabilities,
            "settings_schema" => Keyword.get(opts, :settings_schema, [])
          },
          wasm_module: guest_wasm(),
          granted_capabilities: granted,
          enabled: Keyword.get(opts, :enabled, true),
          settings: Keyword.get(opts, :settings, %{})
        })

      config
    end

    defp base_caps,
      do: %{"events:subscribe" => ["media_item.added"], "net:http" => ["discord.com"]}

    test "a revision requesting a strictly new capability class is detected" do
      config = seed_installed!(base_caps())
      refute Plugins.needs_reapproval?(config)

      revised = revise!(config, Map.put(base_caps(), "data:read", ["media_item"]))

      assert Plugins.ungranted_capabilities(revised) == %{"data:read" => ["media_item"]}
      assert Plugins.needs_reapproval?(revised)
    end

    test "a revision widening a capability payload is detected" do
      config = seed_installed!(base_caps())

      revised =
        revise!(config, %{
          "events:subscribe" => ["media_item.added", "download.completed"],
          "net:http" => ["discord.com", "api.example.com"]
        })

      assert Plugins.ungranted_capabilities(revised) == %{
               "events:subscribe" => ["download.completed"],
               "net:http" => ["api.example.com"]
             }
    end

    test "a revision that only changes name and version is not flagged" do
      config = seed_installed!(base_caps())

      {:ok, revised} =
        Settings.update_plugin_config(config, %{
          name: "Webhook Notifier (renamed)",
          version: "2.0.0",
          manifest: Map.merge(config.manifest, %{"name" => "Renamed", "version" => "2.0.0"})
        })

      assert Plugins.ungranted_capabilities(revised) == %{}
      refute Plugins.needs_reapproval?(revised)
    end

    test "a revision that narrows the declared set is not flagged" do
      config = seed_installed!(base_caps())
      revised = revise!(config, %{"events:subscribe" => ["media_item.added"]})

      refute Plugins.needs_reapproval?(revised)
    end

    test "an operator-configured host in the grant does not look like drift" do
      config =
        seed_installed!(base_caps(),
          granted: Map.put(base_caps(), "net:http", ["discord.com", "ntfy.example.com"])
        )

      refute Plugins.needs_reapproval?(config)
    end

    test "a plugin holding no grant is pending approval, not awaiting re-approval" do
      config = seed_installed!(base_caps(), granted: %{}, enabled: false)

      refute Plugins.needs_reapproval?(config)
      assert Plugins.ungranted_capabilities(config) == base_caps()
    end

    test "a config with no stored manifest (env-sourced) reports nothing" do
      config = %Mydia.Settings.PluginConfig{
        slug: "env-plugin",
        manifest: nil,
        granted_capabilities: %{"net:http" => ["discord.com"]}
      }

      assert Plugins.ungranted_capabilities(config) == %{}
      refute Plugins.needs_reapproval?(config)
    end

    test "a revision never widens the stored grant on its own" do
      config = seed_installed!(base_caps())
      revised = revise!(config, Map.put(base_caps(), "data:read", ["media_item"]))

      assert revised.granted_capabilities == base_caps()

      assert Settings.get_plugin_config_by_slug("webhook-notifier").granted_capabilities ==
               base_caps()
    end

    test "re-approving grants the currently requested set and clears the state" do
      config = seed_installed!(base_caps())

      revised =
        revise!(config, %{
          "events:subscribe" => ["media_item.added", "download.completed"],
          "net:http" => ["discord.com", "api.example.com"],
          "data:read" => ["media_item"]
        })

      assert Plugins.needs_reapproval?(revised)

      assert {:ok, descriptor} = Plugins.approve("webhook-notifier")

      reloaded = Settings.get_plugin_config_by_slug("webhook-notifier")
      refute Plugins.needs_reapproval?(reloaded)
      assert Plugins.ungranted_capabilities(reloaded) == %{}
      assert reloaded.granted_capabilities["data:read"] == ["media_item"]
      assert "api.example.com" in reloaded.granted_capabilities["net:http"]
      assert "download.completed" in reloaded.granted_capabilities["events:subscribe"]

      # The live descriptor enforces the new grant without a restart.
      assert descriptor.granted_capabilities["data:read"] == ["media_item"]
      {:ok, registered} = Registry.lookup("webhook-notifier")
      assert "api.example.com" in registered.granted_capabilities["net:http"]
    end

    test "saving settings does not grant hosts a revised manifest newly declares" do
      config =
        seed_installed!(base_caps(),
          settings_schema: [%{"key" => "webhook_url", "type" => "url", "grants_host" => true}]
        )

      revise!(config, Map.put(base_caps(), "net:http", ["discord.com", "sneaky.example.com"]))

      assert {:ok, updated} =
               Plugins.update_settings("webhook-notifier", %{
                 "webhook_url" => "https://ntfy.example.com/mydia"
               })

      hosts = updated.granted_capabilities["net:http"]
      assert "discord.com" in hosts
      assert "ntfy.example.com" in hosts
      refute "sneaky.example.com" in hosts
      assert Plugins.needs_reapproval?(updated)
    end
  end

  describe "ensure_bundled/0 manifest reconciliation" do
    test "refreshes a stale stored manifest while leaving admin state untouched" do
      # A bundled row seeded before settings_schema was added to the JSON: its
      # stored manifest lacks the field, so the Settings UI can't render.
      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: "webhook-notifier",
          name: "Webhook Notifier",
          version: "1.0.0",
          source_url: "bundled",
          enabled: true,
          granted_capabilities: %{"net:http" => ["discord.com"]},
          settings: %{"target" => "ntfy"},
          manifest: %{
            "slug" => "webhook-notifier",
            "name" => "Webhook Notifier",
            "version" => "1.0.0",
            "capabilities" => %{"net:http" => ["discord.com"]}
          }
        })

      refute get_in(config.manifest, ["settings_schema"])

      Plugins.ensure_bundled()

      refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")
      schema = get_in(refreshed.manifest, ["settings_schema"])

      assert is_list(schema) and schema != []
      assert Enum.any?(schema, &(&1["key"] == "webhook_url" and &1["grants_host"] == true))

      # Admin state must survive a built-in upgrade.
      assert refreshed.enabled
      assert refreshed.granted_capabilities == %{"net:http" => ["discord.com"]}
      assert refreshed.settings == %{"target" => "ntfy"}
    end

    test "a built-in upgrade that requests more than was granted is flagged for re-approval" do
      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: "webhook-notifier",
          name: "Webhook Notifier",
          version: "1.0.0",
          source_url: "bundled",
          enabled: true,
          granted_capabilities: %{"net:http" => ["discord.com"]},
          manifest: %{
            "slug" => "webhook-notifier",
            "name" => "Webhook Notifier",
            "version" => "1.0.0",
            "capabilities" => %{"net:http" => ["discord.com"]}
          }
        })

      # Before the upgrade the grant matches the declaration exactly.
      refute Plugins.needs_reapproval?(config)

      Plugins.ensure_bundled()

      refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert Plugins.needs_reapproval?(refreshed)
      assert Map.has_key?(Plugins.ungranted_capabilities(refreshed), "events:subscribe")

      # ...and the grant itself was left exactly as approved.
      assert refreshed.granted_capabilities == %{"net:http" => ["discord.com"]}
    end
  end

  describe "maybe_ensure_bundled/0 gate" do
    test "no-ops when boot-time side effects are disabled (the test default)" do
      # start_health_monitors: false in config/test.exs — the same gate that keeps
      # the app's test boot from writing the shared DB also keeps a connected admin
      # mount from seeding, so the empty-state list stays deterministic.
      refute Application.get_env(:mydia, :start_health_monitors, true)

      assert :ok = Plugins.maybe_ensure_bundled()
      assert Settings.get_db_plugin_configs() == []
    end

    test "seeds bundled manifests when enabled, the way an admin page view does" do
      Application.put_env(:mydia, :start_health_monitors, true)
      on_exit(fn -> Application.put_env(:mydia, :start_health_monitors, false) end)

      assert :ok = Plugins.maybe_ensure_bundled()

      slugs = Settings.get_db_plugin_configs() |> Enum.map(& &1.slug) |> MapSet.new()
      assert MapSet.member?(slugs, "webhook-notifier")
      assert MapSet.member?(slugs, "simkl_sync")
    end
  end

  describe "detect_updates/2 (R14)" do
    defp config(slug, version), do: %Mydia.Settings.PluginConfig{slug: slug, version: version}

    defp avail(slug, version) do
      %Entry{
        slug: slug,
        name: slug,
        version: version,
        package_url: "https://x/#{slug}.wasm",
        integrity: "sha256:ab",
        manifest: manifest!()
      }
    end

    test "flags a slug with a newer available version" do
      updates = Plugins.detect_updates([config("p", "1.0.0")], [avail("p", "1.2.0")])
      assert [%{slug: "p", current: "1.0.0", latest: "1.2.0"}] = updates
    end

    test "does not flag when versions match" do
      assert [] = Plugins.detect_updates([config("p", "1.0.0")], [avail("p", "1.0.0")])
    end

    test "does not flag when the available version is older" do
      assert [] = Plugins.detect_updates([config("p", "2.0.0")], [avail("p", "1.0.0")])
    end

    test "ignores slugs that are not installed" do
      assert [] = Plugins.detect_updates([config("p", "1.0.0")], [avail("other", "9.0.0")])
    end
  end
end
