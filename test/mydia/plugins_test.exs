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

  describe "install_file/3 (sideloading an unpublished plugin)" do
    @describetag :tmp_dir

    defp write_plugin!(dir, manifest) do
      wasm_path = Path.join(dir, "plugin.wasm")
      manifest_path = Path.join(dir, "manifest.json")
      File.write!(wasm_path, guest_wasm())
      File.write!(manifest_path, manifest |> Plugins.manifest_to_map() |> Jason.encode!())
      {wasm_path, manifest_path}
    end

    test "installs inactive, recording the file and its hash", %{tmp_dir: dir} do
      {wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())

      assert {:ok, :inactive} = Plugins.install_file(wasm_path, manifest_path)

      config = Settings.get_plugin_config_by_slug("page-fixture")
      refute config.enabled
      assert config.granted_capabilities == %{}
      assert config.source_url == "file://" <> wasm_path

      assert config.integrity_hash ==
               :crypto.hash(:sha256, guest_wasm()) |> Base.encode16(case: :lower)

      refute Host.running?("page-fixture")
    end

    test "approve: true activates it and lists its page", %{tmp_dir: dir} do
      {wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())

      assert {:ok, descriptor} = Plugins.install_file(wasm_path, manifest_path, approve: true)
      assert descriptor.enabled
      assert Host.running?("page-fixture")
      assert [%{slug: "page-fixture"}] = Plugins.list_pages()
    end

    test "reinstalling a running plugin stops it until re-approved", %{tmp_dir: dir} do
      {wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())
      assert {:ok, _} = Plugins.install_file(wasm_path, manifest_path, approve: true)
      assert Host.running?("page-fixture")

      assert {:ok, :inactive} = Plugins.install_file(wasm_path, manifest_path)
      refute Host.running?("page-fixture")
      refute Registry.registered?("page-fixture")
    end

    test "rejects an invalid manifest before persisting anything", %{tmp_dir: dir} do
      {wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())
      File.write!(manifest_path, ~s({"slug": "page-fixture"}))

      assert {:error, %{type: :invalid_manifest}} = Plugins.install_file(wasm_path, manifest_path)
      assert Settings.get_plugin_config_by_slug("page-fixture") == nil
    end

    test "reports a missing file", %{tmp_dir: dir} do
      {_wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())

      assert {:error, %{type: :invalid_config, message: message}} =
               Plugins.install_file(Path.join(dir, "missing.wasm"), manifest_path)

      assert message =~ "cannot read package"
    end

    test "refuses to replace a bundled plugin", %{tmp_dir: dir} do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "page-fixture",
          name: "Page Fixture",
          version: "1.0.0",
          source_url: "bundled",
          granted_capabilities: %{},
          enabled: false
        })

      {wasm_path, manifest_path} = write_plugin!(dir, page_manifest!())

      assert {:error, %{message: message}} = Plugins.install_file(wasm_path, manifest_path)
      assert message =~ "PLUGINS_OVERRIDE_DIR"
      assert Settings.get_plugin_config_by_slug("page-fixture").source_url == "bundled"
    end
  end

  describe "page plugins" do
    defp page_manifest! do
      manifest!(%{
        "slug" => "page-fixture",
        "name" => "Page Fixture",
        "min_host_version" => "0.0.0-dev",
        "capabilities" => %{"surfaces:page" => []},
        "page" => %{"title" => "Fixture", "icon" => "hero-sparkles"},
        "settings_schema" => [
          %{
            "key" => "endpoint",
            "type" => "url",
            "grants_host" => true,
            "allow_private" => true
          }
        ]
      })
    end

    test "the stored manifest map re-parses to the same manifest" do
      manifest = page_manifest!()

      assert {:ok, ^manifest} =
               manifest |> Plugins.manifest_to_map() |> Manifest.parse()
    end

    test "installing a page plugin activates it and lists its page", %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)

      assert {:ok, descriptor} =
               Plugins.install(entry(bypass, page_manifest!(), wasm), gate_opts())

      assert descriptor.enabled
      assert Host.running?("page-fixture")

      assert [%{slug: "page-fixture", title: "Fixture", icon: "hero-sparkles"}] =
               Plugins.list_pages()
    end

    test "approving a page plugin activates it", %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)

      assert {:ok, :inactive} =
               Plugins.install(
                 entry(bypass, page_manifest!(), wasm),
                 [grants: %{}] ++ gate_opts()
               )

      assert {:ok, _} = Plugins.approve("page-fixture")
      assert Host.running?("page-fixture")
      assert [%{slug: "page-fixture"}] = Plugins.list_pages()
    end

    test "a failed activation leaves the row disabled, not enabled with no live plugin" do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "broken-page",
          name: "Broken",
          version: "1.0.0",
          manifest: %{
            "slug" => "broken-page",
            "name" => "Broken",
            "version" => "1.0.0",
            "capabilities" => %{"surfaces:page" => []}
          },
          wasm_module: guest_wasm(),
          granted_capabilities: %{},
          enabled: false
        })

      assert {:error, %{type: :invalid_manifest}} = Plugins.approve("broken-page")
      assert Settings.get_plugin_config_by_slug("broken-page").enabled == false
      refute Registry.registered?("broken-page")
    end
  end

  describe "declared settings (PLUGIN_<N>_SETTINGS / plugin_settings:)" do
    alias Mydia.Config.Schema
    alias Mydia.Plugins.DeclaredSettings

    defp declare_settings(slug, settings) do
      base = Application.get_env(:mydia, :runtime_config) || Schema.defaults()

      decl = %Schema.PluginSettingsDecl{slug: slug, settings: settings}
      Application.put_env(:mydia, :runtime_config, %{base | plugin_settings: [decl]})
      # The outer setup's on_exit restores :runtime_config to its original value.
    end

    defp declared_manifest do
      manifest!(%{
        "settings_schema" => [
          %{"key" => "base_url", "type" => "url", "grants_host" => true, "allow_private" => true}
        ]
      })
    end

    test "install applies declared settings and grants the declared host", %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)
      declare_settings("webhook-notifier", %{"base_url" => "http://ollama.lan:11434/v1"})

      assert {:ok, _} =
               Plugins.install(
                 entry(bypass, declared_manifest(), wasm),
                 [grants: %{"net:http" => ["discord.com"]}] ++ gate_opts()
               )

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["base_url"] == "http://ollama.lan:11434/v1"
      assert "ollama.lan" in config.granted_capabilities["net:http"]
    end

    test "a failed activation after a settings sync leaves no registered descriptor" do
      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: "ghost-plugin",
          name: "Ghost",
          version: "1.0.0",
          manifest:
            Plugins.manifest_to_map(
              manifest!(%{
                "slug" => "ghost-plugin",
                "settings_schema" => [%{"key" => "model", "type" => "string"}]
              })
            ),
          granted_capabilities: %{"net:http" => ["discord.com"]},
          enabled: true
        })

      declare_settings("ghost-plugin", %{"model" => "m"})
      DeclaredSettings.sync("ghost-plugin")
      assert Registry.registered?("ghost-plugin")

      assert {:error, _} = Plugins.set_enabled("ghost-plugin", true)

      refute Registry.registered?("ghost-plugin")
      assert Settings.get_plugin_config_by_slug("ghost-plugin").enabled == false
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

    test "remove purges grants and pending writes but keeps the journal, still undoable" do
      user = Mydia.AccountsFixtures.user_fixture()
      slug = "webhook-notifier"
      :ok = Mydia.Plugins.Grants.grant(slug, user.id, "collections:write", "always", "s")

      {:ok, _} =
        %Mydia.Plugins.PendingWrite{}
        |> Mydia.Plugins.PendingWrite.changeset(%{
          plugin_slug: slug,
          user_id: user.id,
          session_id: "s",
          op: "collection_create",
          surface: "collections:write",
          args: %{},
          description: "d",
          expires_at: DateTime.add(DateTime.utc_now(), 3600) |> DateTime.truncate(:second)
        })
        |> Mydia.Repo.insert()

      args = %{"name" => "Kept", "type" => "manual"}

      {:ok, result, inverse} =
        Mydia.Plugins.PageWrites.execute("collection_create", args, user, "plugin:#{slug}")

      {:ok, entry} =
        Mydia.Plugins.Journal.record(
          slug,
          user.id,
          "collection_create",
          args,
          result,
          inverse,
          "Create the collection \"Kept\"",
          "b1"
        )

      assert {:ok, :removed} = Plugins.remove(slug)

      assert Mydia.Plugins.Grants.list_for_user(user.id) == []
      refute Mydia.Repo.exists?(Ecto.Query.from(p in Mydia.Plugins.PendingWrite))
      # A plugin installed later under the same slug starts with no approval.
      refute Mydia.Plugins.Grants.granted?(slug, user.id, "collections:write", "s2")

      assert [%{id: id}] = Mydia.Plugins.Journal.list(slug, user.id)
      assert id == entry.id
      assert {:ok, %{status: "undone"}} = Mydia.Plugins.Journal.undo_entry(user, entry.id)
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

  describe "update_settings/2 and instances" do
    test "saved settings reach a single-instance plugin's injected config", %{bypass: bypass} do
      wasm = guest_wasm()
      serve_package(bypass, wasm)
      {:ok, _} = Plugins.install(entry(bypass, manifest!(), wasm), gate_opts())

      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{"webhook_url" => "https://x.test/h"})

      instance = Mydia.Plugins.Instances.default_instance("webhook-notifier")
      assert Mydia.Plugins.Instances.config_for(instance)["webhook_url"] == "https://x.test/h"
    end

    test "activation heals settings saved before they reached the default instance", %{
      bypass: bypass
    } do
      wasm = guest_wasm()
      serve_package(bypass, wasm)
      {:ok, _} = Plugins.install(entry(bypass, manifest!(), wasm), gate_opts())
      config = Settings.get_plugin_config_by_slug("webhook-notifier")

      {:ok, _} =
        Settings.update_plugin_config(config, %{settings: %{"stale" => "no", "k" => "v"}})

      {:ok, descriptor} = Registry.lookup("webhook-notifier")
      Plugins.ensure_default_instance(descriptor)

      instance = Mydia.Plugins.Instances.default_instance("webhook-notifier")
      assert Mydia.Plugins.Instances.config_for(instance)["k"] == "v"
    end

    test "a multi_instance plugin's plugin-level settings never widen net:http", %{
      bypass: bypass
    } do
      wasm = guest_wasm()
      serve_package(bypass, wasm)

      manifest =
        manifest!(%{
          "multi_instance" => true,
          "settings_schema" => [%{"key" => "server_url", "type" => "url", "grants_host" => true}]
        })

      {:ok, _} = Plugins.install(entry(bypass, manifest, wasm), gate_opts())

      {:ok, _} =
        Plugins.update_settings("webhook-notifier", %{
          "server_url" => "https://evil.example.com/x"
        })

      assert Settings.get_plugin_config_by_slug("webhook-notifier").granted_capabilities[
               "net:http"
             ] == ["discord.com"]

      assert Mydia.Plugins.Instances.list("webhook-notifier") == []
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
    # A revision re-stores the declared manifest and never touches
    # `granted_capabilities` — the non-bundled install/re-approval path.
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
    test "refreshes manifest and exact effective grant while preserving enabled state and settings" do
      settings = %{
        "target" => "ntfy",
        "webhook_url" => "https://ntfy.example.com/mydia"
      }

      {:ok, _config} =
        Settings.create_plugin_config(%{
          slug: "webhook-notifier",
          name: "Old Notifier",
          version: "1.0.0",
          source_url: "bundled",
          enabled: true,
          granted_capabilities: %{
            "net:http" => ["discord.com"],
            "obsolete" => ["remove-me"]
          },
          settings: settings,
          manifest: %{
            "slug" => "webhook-notifier",
            "name" => "Old Notifier",
            "version" => "1.0.0",
            "capabilities" => %{"net:http" => ["discord.com"]}
          }
        })

      assert :ok = Plugins.ensure_bundled()

      refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")

      expected =
        refreshed.manifest["capabilities"]
        |> Map.put("net:http", ["discord.com", "ntfy.example.com"])

      assert refreshed.enabled
      # The shipped delivery mode is merged in; the operator's keys survive.
      assert refreshed.settings == Map.put(settings, "delivery", "durable")
      assert refreshed.granted_capabilities == expected
      refute Plugins.needs_reapproval?(refreshed)
    end

    test "refreshes a disabled bundled plugin grant without enabling it" do
      {:ok, _config} =
        Settings.create_plugin_config(%{
          slug: "webhook-notifier",
          name: "Webhook Notifier",
          version: "1.0.0",
          source_url: "bundled",
          enabled: false,
          granted_capabilities: %{
            "net:http" => ["discord.com"],
            "obsolete" => ["remove-me"]
          },
          settings: %{"delivery" => "durable"},
          manifest: %{
            "slug" => "webhook-notifier",
            "name" => "Webhook Notifier",
            "version" => "1.0.0",
            "capabilities" => %{"net:http" => ["discord.com"]}
          }
        })

      assert :ok = Plugins.ensure_bundled()

      refreshed = Settings.get_plugin_config_by_slug("webhook-notifier")
      refute refreshed.enabled
      assert refreshed.granted_capabilities == refreshed.manifest["capabilities"]
      refute Map.has_key?(refreshed.granted_capabilities, "obsolete")
      refute Plugins.needs_reapproval?(refreshed)
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

    test "starts a bundled plugin discovered on a running node, so its enabled row is not left unregistered" do
      Application.put_env(:mydia, :start_health_monitors, true)
      on_exit(fn -> Application.put_env(:mydia, :start_health_monitors, false) end)

      refute Host.running?("webhook-notifier")

      assert :ok = Plugins.maybe_ensure_bundled()

      assert Host.running?("webhook-notifier")
    end

    test "is idempotent and never starts a bundled plugin the operator disabled" do
      Application.put_env(:mydia, :start_health_monitors, true)
      on_exit(fn -> Application.put_env(:mydia, :start_health_monitors, false) end)

      {:ok, _config} =
        Settings.create_plugin_config(%{
          slug: "simkl_sync",
          name: "Simkl Sync",
          version: "1.1.0",
          source_url: "bundled",
          enabled: false,
          granted_capabilities: %{"net:http" => ["api.simkl.com"]},
          settings: %{},
          manifest: %{
            "slug" => "simkl_sync",
            "name" => "Simkl Sync",
            "version" => "1.1.0",
            "capabilities" => %{"net:http" => ["api.simkl.com"]}
          }
        })

      assert :ok = Plugins.maybe_ensure_bundled()
      assert :ok = Plugins.maybe_ensure_bundled()

      assert Host.running?("webhook-notifier")
      refute Host.running?("simkl_sync")
    end
  end

  describe "host version floor" do
    test "development builds meet any floor" do
      assert Plugins.host_meets_floor?("9.9.9", "0.0.0-dev")
    end

    test "a release below the floor fails" do
      refute Plugins.host_meets_floor?("0.16.0", "0.15.0")
    end

    test "a beta of the floor's release meets it" do
      assert Plugins.host_meets_floor?("0.16.0", "0.16.0-beta.1")
      assert Plugins.host_meets_floor?("0.16.0", "0.17.0")
    end

    test "a bundled plugin activates on a release host despite its floor" do
      Application.put_env(:mydia, :start_health_monitors, true)
      Application.put_env(:mydia, :plugin_host_version, "0.15.0")

      on_exit(fn ->
        Application.put_env(:mydia, :start_health_monitors, false)
        Application.delete_env(:mydia, :plugin_host_version)
      end)

      assert :ok = Plugins.maybe_ensure_bundled()
      assert Host.running?("simkl_sync")
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
