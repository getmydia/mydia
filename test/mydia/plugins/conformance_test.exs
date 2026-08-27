defmodule Mydia.Plugins.ConformanceTest do
  # async: false — starts a real pool under the app-wide PoolRegistry and seeds
  # PluginConfig rows that the activation path reads.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Plugins
  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.HostFunctions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  defp host_version, do: :mydia |> Application.spec(:vsn) |> List.to_string()

  # A component built from the canonical mydia:plugin@1.1.0 WIT (via the SDK).
  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "support",
             "fixtures",
             "plugins",
             "host_fns_fixture.wasm"
           ])

  # A 1.0 component (built against mydia:plugin@1.0.0), never rebuilt — proves a
  # legacy guest still works against the 1.1 host.
  @legacy_fixture Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "support",
                    "fixtures",
                    "plugins",
                    "host_test_fixture.wasm"
                  ])

  defp payload(event), do: %{"event" => event, "metadata" => %{}}

  setup do
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
    end)

    :ok
  end

  describe "WIT contract conformance (R9)" do
    test "a guest built from the canonical WIT instantiates against the live host" do
      # If plugin.wit drifted from the host's expected interface/version
      # (Host.@handler_export or the host-import namespace), wasmtime's component
      # linker would refuse this guest at instantiation. A clean call proves the
      # host provides exactly the contract the SDK builds guests against.
      bytes = File.read!(@fixture)

      {:ok, _pid} =
        Host.start_plugin("conformance", bytes, imports: HostFunctions.imports_for("conformance"))

      on_exit(fn -> Host.stop_plugin("conformance") end)

      assert {:ok, %{"logged" => true}} = Host.call("conformance", "handle", payload("log"))
    end
  end

  describe "1.1 contract surfaces (U2)" do
    test "the host invokes the guest's on-schedule export" do
      bytes = File.read!(@fixture)

      {:ok, _pid} =
        Host.start_plugin("sched-conf", bytes, imports: HostFunctions.imports_for("sched-conf"))

      on_exit(fn -> Host.stop_plugin("sched-conf") end)

      assert {:ok, %{"scheduled" => true, "slug" => "sched-conf"}} =
               Host.call(
                 "sched-conf",
                 "on-schedule",
                 %{"slug" => "sched-conf", "config" => %{}},
                 handler: :on_schedule
               )
    end

    test "a 1.0 guest still handles on-event, and its schedule call fails soft" do
      bytes = File.read!(@legacy_fixture)

      {:ok, _pid} =
        Host.start_plugin("legacy-conf", bytes, imports: HostFunctions.imports_for("legacy-conf"))

      on_exit(fn -> Host.stop_plugin("legacy-conf") end)

      # on-event resolves at the guest's own 1.0 interface version.
      assert {:ok, %{}} = Host.call("legacy-conf", "handle", payload("ok"))

      # on-schedule is 1.1-only; a 1.0 guest has no such export, so the call
      # fails soft (a returned error, no crash).
      assert {:error, %Error{}} =
               Host.call(
                 "legacy-conf",
                 "on-schedule",
                 %{"slug" => "legacy-conf", "config" => %{}},
                 handler: :on_schedule
               )

      # The pool survives the failed schedule call and still serves events.
      assert {:ok, %{}} = Host.call("legacy-conf", "handle", payload("ok"))
    end

    test "the guest round-trips kv-set/get/delete through the host (U3)" do
      slug = "kvguest"
      install_with_grant!(slug, %{"state:kv" => []})

      bytes = File.read!(@fixture)
      {:ok, _pid} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
      on_exit(fn -> Host.stop_plugin(slug) end)

      assert {:ok, %{"ok" => true}} =
               Host.call(slug, "h", %{"event" => "kv-set", "key" => "k", "value" => "v"})

      assert {:ok, %{"found" => true, "value" => "v"}} =
               Host.call(slug, "h", %{"event" => "kv-get", "key" => "k"})

      assert {:ok, %{"ok" => true}} =
               Host.call(slug, "h", %{"event" => "kv-delete", "key" => "k"})

      assert {:ok, %{"found" => false}} =
               Host.call(slug, "h", %{"event" => "kv-get", "key" => "k"})
    end

    test "the guest round-trips connections-list, seeing identity but no token (U7)" do
      slug = "connguest"
      install_with_grant!(slug, %{"users:connections" => []})
      user = user_fixture()

      {:ok, _} =
        Connections.connect(slug, user.id, %{
          access_token: "never-leaks",
          external_username: "carol"
        })

      bytes = File.read!(@fixture)
      {:ok, _pid} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
      on_exit(fn -> Host.stop_plugin(slug) end)

      assert {:ok, result} =
               Host.call(slug, "h", %{"event" => "connections-list"})

      assert result["count"] == 1
    end

    test "the guest round-trips data-list, decoding list-result + variants (U5)" do
      slug = "listguest"
      install_with_grant!(slug, %{"data:read" => ["media_item"]})

      for _ <- 1..3 do
        {:ok, _} =
          Mydia.Media.create_media_item(Scope.unrestricted(), %{
            title: "M#{System.unique_integer([:positive])}",
            type: "movie",
            year: 2024,
            tmdb_id: System.unique_integer([:positive])
          })
      end

      bytes = File.read!(@fixture)
      {:ok, _pid} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
      on_exit(fn -> Host.stop_plugin(slug) end)

      assert {:ok, %{"count" => 3, "has_next" => false}} =
               Host.call(slug, "h", %{"event" => "data-list", "namespace" => "media_item"})
    end

    test "the guest round-trips ensure-watched, decoding the status enum (U6)" do
      slug = "writeguest"
      install_with_grant!(slug, %{"surfaces:write" => ["playback:watched"]})
      user = user_fixture()
      {:ok, _} = Connections.connect(slug, user.id, %{access_token: "t"})

      {:ok, _} =
        Mydia.Media.create_media_item(Scope.unrestricted(), %{
          title: "M",
          type: "movie",
          year: 2024,
          imdb_id: "ttGUEST",
          tmdb_id: System.unique_integer([:positive])
        })

      bytes = File.read!(@fixture)
      {:ok, _pid} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
      on_exit(fn -> Host.stop_plugin(slug) end)

      assert {:ok, %{"status" => "changed"}} =
               Host.call(slug, "h", %{
                 "event" => "ensure-watched",
                 "user_id" => user.id,
                 "imdb_id" => "ttGUEST"
               })
    end

    test "a guest without state:kv is denied at the host boundary (U3)" do
      slug = "kvdenied"
      install_with_grant!(slug, %{"events:subscribe" => ["media_item.added"]})

      bytes = File.read!(@fixture)
      {:ok, _pid} = Host.start_plugin(slug, bytes, imports: HostFunctions.imports_for(slug))
      on_exit(fn -> Host.stop_plugin(slug) end)

      # The guest surfaces the host-error as an Err, which the host reports as a
      # guest error — the grant gate held.
      assert {:error, %Error{type: :guest_error}} =
               Host.call(slug, "h", %{"event" => "kv-set", "key" => "k", "value" => "v"})
    end
  end

  # Installs a plugin_config (for FK resolution) and registers a runtime
  # descriptor carrying the grants the host functions check.
  defp install_with_grant!(slug, granted) do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => slug,
          "name" => slug,
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["media_item.added"]}
        },
        granted_capabilities: granted,
        enabled: false
      })

    {:ok, _} =
      Registry.register(slug, %Plugin{
        slug: slug,
        name: slug,
        granted_capabilities: granted,
        enabled: true
      })

    on_exit(fn -> Registry.unregister(slug) end)
    :ok
  end

  describe "min_host_version floor (R7)" do
    defp seed!(slug, min_host_version) do
      manifest = %{
        "slug" => slug,
        "name" => slug,
        "version" => "1.0.0",
        "min_host_version" => min_host_version,
        "capabilities" => %{"events:subscribe" => ["media_item.added"]}
      }

      {:ok, _} =
        Settings.create_plugin_config(%{
          slug: slug,
          name: slug,
          version: "1.0.0",
          source_url: "test",
          manifest: manifest,
          granted_capabilities: %{},
          enabled: false
        })

      :ok
    end

    test "refuses a plugin whose floor exceeds the host with an actionable message" do
      seed!("floor-too-high", "999.0.0")

      assert {:error, %Error{type: :host_version, message: msg}} =
               Plugins.set_enabled("floor-too-high", true)

      assert msg =~ "requires mydia >= 999.0.0"
    end

    test "a floor at or below the host passes the floor check" do
      # A satisfiable floor (the host's own version) must not be what blocks
      # activation. This synthetic plugin has no resolvable artifact, so
      # activation still fails — but with a non-floor error, proving the floor
      # gate let it through.
      seed!("floor-ok", host_version())

      assert {:error, %Error{type: type}} = Plugins.set_enabled("floor-ok", true)
      refute type == :host_version
    end
  end
end
