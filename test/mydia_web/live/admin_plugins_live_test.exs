defmodule MydiaWeb.AdminPluginsLiveTest do
  # async: false — connected LiveView under the Postgres sandbox, and activation
  # starts pools under the app-wide PoolRegistry.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Index.BrowseResult
  alias Mydia.Plugins.Index.CatalogItem
  alias Mydia.Plugins.Index.Entry
  alias Mydia.Plugins.Registry
  alias Mydia.Settings
  alias MydiaWeb.AdminPluginsLive.Components

  # A prebuilt wasm32-wasip2 component (the host only accepts components, not
  # core-wasm modules) — see test/support/fixtures/plugins/host_test_fixture/.
  @guest_fixture Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "support",
                   "fixtures",
                   "plugins",
                   "host_test_fixture.wasm"
                 ])

  defp guest_wasm, do: File.read!(@guest_fixture)

  defp manifest_map(slug, name) do
    %{
      "slug" => slug,
      "name" => name,
      "version" => "1.0.0",
      "capabilities" => %{
        "events:subscribe" => ["media_item.added"],
        "net:http" => ["discord.com"]
      }
    }
  end

  defp seed_plugin(slug, name, opts) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        manifest: manifest_map(slug, name),
        wasm_module: guest_wasm(),
        granted_capabilities: Keyword.get(opts, :granted, %{}),
        enabled: Keyword.get(opts, :enabled, false)
      })

    config
  end

  defp seed_from(slug, name, source_url) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        source_url: source_url,
        manifest: manifest_map(slug, name),
        wasm_module: guest_wasm(),
        granted_capabilities: %{"net:http" => ["discord.com"]},
        enabled: false
      })

    config
  end

  defp seed_described_plugin(slug, name, description, opts) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        manifest: Map.put(manifest_map(slug, name), "description", description),
        wasm_module: guest_wasm(),
        granted_capabilities: Keyword.get(opts, :granted, %{}),
        enabled: false
      })

    config
  end

  # Points the store at `index_url` only. The file's setup restores
  # :runtime_config on exit.
  defp put_plugin_sources(index_url) do
    base = Application.get_env(:mydia, :runtime_config) || Mydia.Config.Schema.defaults()

    plugins = %{
      base.plugins
      | index_url: index_url,
        index_public_key: Mydia.MinisignFixtures.keypair().public
    }

    Application.put_env(:mydia, :runtime_config, %{base | plugins: plugins})
  end

  defp schema_manifest_map(slug, name) do
    Map.put(manifest_map(slug, name), "settings_schema", [
      %{
        "key" => "target",
        "type" => "enum",
        "label" => "Target service",
        "options" => ["discord", "ntfy"]
      },
      %{
        "key" => "webhook_url",
        "type" => "url",
        "label" => "Webhook / server URL",
        "grants_host" => true
      },
      %{"key" => "ntfy_token", "type" => "secret", "label" => "Access token"}
    ])
  end

  # Schema exercising `visible_when`: ntfy_tags shows only for target=ntfy,
  # body/query templates only for target=custom.
  defp visibility_manifest_map(slug, name) do
    Map.put(manifest_map(slug, name), "settings_schema", [
      %{
        "key" => "target",
        "type" => "enum",
        "label" => "Target service",
        "options" => ["discord", "ntfy", "custom"]
      },
      %{
        "key" => "webhook_url",
        "type" => "url",
        "label" => "Webhook / server URL",
        "grants_host" => true
      },
      %{
        "key" => "ntfy_tags",
        "type" => "string",
        "label" => "Tags",
        "visible_when" => %{"target" => "ntfy"}
      },
      %{
        "key" => "body_template",
        "type" => "text",
        "label" => "Body template",
        "visible_when" => %{"target" => "custom"}
      },
      %{
        "key" => "query_template",
        "type" => "string",
        "label" => "Query params",
        "visible_when" => %{"target" => "custom"}
      }
    ])
  end

  defp seed_with_visibility(slug, name, opts) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        manifest: visibility_manifest_map(slug, name),
        wasm_module: guest_wasm(),
        granted_capabilities: %{
          "net:http" => ["discord.com"],
          "events:subscribe" => ["media_item.added"]
        },
        enabled: true,
        settings: Keyword.get(opts, :settings, %{})
      })

    config
  end

  defp seed_with_hints(slug, name) do
    manifest =
      Map.put(manifest_map(slug, name), "settings_schema", [
        %{
          "key" => "model",
          "type" => "string",
          "label" => "Default model",
          "hint" => "Users can change it"
        },
        %{
          "key" => "base_url",
          "type" => "url",
          "label" => "Server URL",
          "hint" => "For example http://ollama.lan:11434",
          "grants_host" => true,
          "allow_private" => true
        }
      ])

    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        manifest: manifest,
        wasm_module: guest_wasm(),
        granted_capabilities: %{
          "net:http" => ["discord.com"],
          "events:subscribe" => ["media_item.added"]
        },
        enabled: true
      })

    config
  end

  defp seed_with_schema(slug, name, opts) do
    {:ok, config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: name,
        version: "1.0.0",
        manifest: schema_manifest_map(slug, name),
        wasm_module: guest_wasm(),
        granted_capabilities:
          Keyword.get(opts, :granted, %{
            "net:http" => ["discord.com"],
            "events:subscribe" => ["media_item.added"]
          }),
        enabled: Keyword.get(opts, :enabled, true),
        settings: Keyword.get(opts, :settings, %{})
      })

    config
  end

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique}@example.com",
        username: "admin_#{unique}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _} = Mydia.Auth.Guardian.encode_and_sign(user)

    # Approval/lifecycle events call Plugins.reload/0, which replaces the global
    # :runtime_config — restore it so the pollution doesn't outlive the test.
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

    conn =
      conn
      |> init_test_session(%{})
      |> put_session(:guardian_default_token, token)
      |> put_req_header("authorization", "Bearer #{token}")

    %{conn: conn}
  end

  test "redirects unauthenticated users", %{} do
    {:error, {:redirect, %{to: path}}} = live(build_conn(), ~p"/admin/plugins")
    assert path =~ "/auth"
  end

  test "renders an empty state when no plugins are installed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/plugins")
    assert has_element?(view, "#plugins-installed")
    assert render(view) =~ "No plugins installed"
  end

  describe "store browsing" do
    test "an empty store opens the modal and says so", %{conn: conn} do
      put_plugin_sources("")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#browse-store") |> render_click()
      render_async(view)

      assert has_element?(view, "#store-modal #catalog-empty")
      refute has_element?(view, "#store-modal #plugin-catalog")
      refute has_element?(view, "#store-modal #browse-error")
    end

    test "a failing source opens the modal with the error", %{conn: conn} do
      # Non-https fails in require_https/2 before any network I/O.
      put_plugin_sources("http://insecure.test/index.json")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#browse-store") |> render_click()
      render_async(view)

      assert has_element?(view, "#store-modal #browse-error")
      refute has_element?(view, "#store-modal #catalog-empty")
    end

    test "Close dismisses the store", %{conn: conn} do
      put_plugin_sources("")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#browse-store") |> render_click()
      render_async(view)
      view |> element("#close-store") |> render_click()

      refute has_element?(view, "#store-modal")
    end

    test "an approval hides the store, and declining brings it back", %{conn: conn} do
      seed_plugin("webhook-notifier", "Webhook Notifier", enabled: false)
      put_plugin_sources("")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#browse-store") |> render_click()
      render_async(view)
      view |> element("#approve-webhook-notifier") |> render_click()

      assert has_element?(view, "#approval-modal")
      refute has_element?(view, "#store-modal")

      view |> element("#decline-approval") |> render_click()
      assert has_element?(view, "#store-modal")
    end

    test "the store modal shows a spinner before results arrive" do
      doc =
        render_component(&Components.store_modal/1, browse: nil)
        |> LazyHTML.from_fragment()

      refute doc |> LazyHTML.query("#store-loading") |> Enum.empty?()
      assert doc |> LazyHTML.query("#plugin-catalog") |> Enum.empty?()
    end

    test "each catalog row offers the action its install state allows" do
      entry = fn slug, version ->
        %Entry{
          slug: slug,
          name: slug,
          version: version,
          package_url: "https://cdn.test/#{slug}.wasm",
          integrity: "sha256:ab",
          manifest: nil
        }
      end

      browse = %BrowseResult{
        status: :available,
        source_count: 1,
        catalog: [
          %CatalogItem{entry: entry.("fresh", "1.0.0"), state: :not_installed},
          %CatalogItem{
            entry: entry.("current", "1.0.0"),
            state: :installed,
            installed_version: "1.0.0"
          },
          %CatalogItem{
            entry: entry.("stale", "1.1.0"),
            state: :update,
            installed_version: "1.0.0"
          },
          %CatalogItem{
            entry: entry.("sideloaded", "1.0.0"),
            state: :replace,
            installed_version: "1.0.0"
          },
          %CatalogItem{
            entry: entry.("builtin", "1.0.0"),
            state: :bundled,
            installed_version: "1.0.0"
          }
        ]
      }

      doc =
        render_component(&Components.store_modal/1, browse: browse)
        |> LazyHTML.from_fragment()

      text = fn selector ->
        doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
      end

      assert text.("#install-official-fresh") == "Install"
      assert text.("#install-official-stale") == "Update to v1.1.0"
      assert text.("#install-official-sideloaded") == "Install store version"
      assert text.("#catalog-state-official-current") == "Installed"
      assert text.("#catalog-state-official-builtin") == "Bundled"
      assert doc |> LazyHTML.query("#install-official-current") |> Enum.empty?()
      assert doc |> LazyHTML.query("#install-official-builtin") |> Enum.empty?()
      assert text.("#catalog-row-official-stale") =~ "(installed v1.0.0)"
    end

    test "third-party entries carry a badge and a namespaced id" do
      sid = Ecto.UUID.generate()

      entry = %Entry{
        slug: "fixture-tool",
        name: "Fixture Tool",
        version: "1.0.0",
        package_url: "https://x.test/p.wasm",
        integrity: "sha256:ab",
        manifest: nil,
        source_id: sid,
        source_name: "Example Plugins"
      }

      browse = %BrowseResult{
        status: :available,
        source_count: 1,
        catalog: [%CatalogItem{entry: entry, state: :not_installed}]
      }

      doc =
        render_component(&Components.store_modal/1, browse: browse) |> LazyHTML.from_fragment()

      key = "src-#{sid}-fixture-tool"

      refute doc |> LazyHTML.query("#install-#{key}") |> Enum.empty?()

      assert doc |> LazyHTML.query("#catalog-third-party-#{key}") |> LazyHTML.text() =~
               "Example Plugins"
    end

    test "an entry installed from another source offers a replace naming it" do
      entry = %Entry{
        slug: "fixture-tool",
        name: "Fixture Tool",
        version: "1.0.0",
        package_url: "https://x.test/p.wasm",
        integrity: "sha256:ab",
        manifest: nil
      }

      item = %CatalogItem{
        entry: entry,
        state: :other_source,
        installed_version: "0.9.0",
        installed_from: "a removed source"
      }

      browse = %BrowseResult{status: :available, source_count: 1, catalog: [item]}

      doc =
        render_component(&Components.store_modal/1, browse: browse) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#install-official-fixture-tool") |> LazyHTML.text() =~
               "Replace"

      assert doc |> LazyHTML.query("#catalog-row-official-fixture-tool") |> LazyHTML.text() =~
               "a removed source"
    end

    test "the store notes how many sources failed" do
      browse = %BrowseResult{
        status: :empty,
        source_count: 2,
        failed_count: 1,
        error: "HTTP 404",
        catalog: []
      }

      doc =
        render_component(&Components.store_modal/1, browse: browse) |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#browse-error") |> LazyHTML.text() =~ "1 of 2 sources"
    end

    test "two sources listing one slug open the approval for the one clicked", %{conn: conn} do
      third_sid = Ecto.UUID.generate()

      entry = fn sid, name ->
        %Entry{
          slug: "fixture-tool",
          name: "Fixture Tool",
          version: "1.0.0",
          package_url: "https://x.test/p.wasm",
          integrity: "sha256:ab",
          manifest: %Mydia.Plugins.Manifest{
            slug: "fixture-tool",
            name: "Fixture Tool",
            version: "1.0.0"
          },
          source_id: sid,
          source_url: "https://plugins.example.test/index.json",
          source_name: name
        }
      end

      browse = %BrowseResult{
        status: :available,
        source_count: 2,
        catalog: [
          %CatalogItem{entry: entry.(nil, nil), state: :not_installed},
          %CatalogItem{entry: entry.(third_sid, "Example Plugins"), state: :not_installed}
        ]
      }

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      # No catalog source is reachable in tests, so seed the browse result the
      # store would hold, then let any message re-render the view.
      :sys.replace_state(view.pid, fn state ->
        socket = Phoenix.Component.assign(state.socket, browse: browse, store_open?: true)
        %{state | socket: socket}
      end)

      send(view.pid, {:event_created, %{type: "unrelated", actor_id: nil}})
      render(view)

      key = "src-#{third_sid}-fixture-tool"
      view |> element("#install-#{key}") |> render_click()

      assert has_element?(
               view,
               "#approval-publisher-warning",
               "Example Plugins (plugins.example.test)"
             )
    end

    test "a source key never equals an official key, whatever the slug" do
      sid = Ecto.UUID.generate()
      source_key = Components.catalog_key(%{source_id: sid, slug: "foo"})

      # Slugs may contain `-`, so try official slugs built to mimic a source key.
      for lookalike <- ["foo--src-" <> sid, "src-#{sid}-foo", "foo-" <> String.slice(sid, 0, 8)] do
        refute Components.catalog_key(%{source_id: nil, slug: lookalike}) == source_key
      end
    end

    test "the button is disabled while a browse is in flight" do
      doc =
        render_component(&Components.header_actions/1, browsing?: true)
        |> LazyHTML.from_fragment()

      refute doc |> LazyHTML.query("#browse-store[disabled]") |> Enum.empty?()
      refute doc |> LazyHTML.query("#browse-store .loading") |> Enum.empty?()
    end
  end

  describe "capability approval (AE1, R7)" do
    test "a pending plugin shows the approval modal with capabilities and network destination, gated until approval",
         %{conn: conn} do
      seed_plugin("webhook-notifier", "Webhook Notifier", enabled: false)

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      # Pending plugin is inactive and offers a review/approve action.
      assert has_element?(view, "#plugin-row-webhook-notifier")
      assert has_element?(view, "#approve-webhook-notifier")
      refute has_element?(view, "#approval-modal")
      refute Host.running?("webhook-notifier")

      # Opening review shows the approval modal with the requested capabilities
      # and the network destination in plain language.
      view |> element("#approve-webhook-notifier") |> render_click()
      assert has_element?(view, "#approval-modal")
      assert has_element?(view, "#approval-capabilities")
      assert has_element?(view, "#approval-capabilities-group-talks_to", "discord.com")
      assert has_element?(view, "#approval-capabilities-also", "reacts to new titles")

      also_text =
        view
        |> element("#approval-capabilities-also")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      assert also_text =~ "reacts to new titles."
      refute also_text =~ " ."
      refute also_text =~ " ,"
      refute render(view) =~ "Review this carefully"
      refute has_element?(view, "#approval-capabilities [data-new]")
      assert has_element?(view, "#confirm-approval")

      # Approving activates the plugin.
      view |> element("#confirm-approval") |> render_click()
      refute has_element?(view, "#approval-modal")
      assert Host.running?("webhook-notifier")
      assert render(view) =~ "active"
    end

    test "a third-party approval names the publisher and what it replaces" do
      approval = %{
        kind: :catalog,
        slug: "fixture-tool",
        name: "Fixture Tool",
        version: "1.0.0",
        capabilities: %{},
        ungranted: %{},
        settings_schema: [],
        publisher: "Example Plugins",
        replaces: "the Mydia plugin index"
      }

      render_approval = fn approval ->
        render_component(&Components.approval_modal/1, approval: approval)
        |> LazyHTML.from_fragment()
      end

      doc = render_approval.(approval)

      assert doc |> LazyHTML.query("#approval-publisher-warning") |> LazyHTML.text() =~
               "Example Plugins"

      assert doc |> LazyHTML.query("#approval-replaces") |> LazyHTML.text() =~
               "the Mydia plugin index"

      doc = render_approval.(%{approval | publisher: nil, replaces: nil})
      assert doc |> LazyHTML.query("#approval-publisher-warning") |> Enum.empty?()
      assert doc |> LazyHTML.query("#approval-replaces") |> Enum.empty?()
    end

    test "declining closes the modal without activating", %{conn: conn} do
      seed_plugin("webhook-notifier", "Webhook Notifier", enabled: false)
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#approve-webhook-notifier") |> render_click()
      view |> element("#decline-approval") |> render_click()

      refute has_element?(view, "#approval-modal")
      refute Host.running?("webhook-notifier")
    end

    test "an approved disabled plugin offers Enable instead of another approval", %{conn: conn} do
      capabilities = manifest_map("notifier", "Notifier")["capabilities"]
      seed_plugin("notifier", "Notifier", enabled: false, granted: capabilities)

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#plugin-row-notifier")
      assert has_element?(view, "#toggle-notifier")
      refute has_element?(view, "#approve-notifier")
      refute has_element?(view, "#reapproval-badge-notifier")
    end
  end

  describe "failing shelves" do
    defp fail_shelf(user, slug, message) do
      user
      |> Mydia.ShelfHelpers.shelf_fixture(slug: slug)
      |> Ecto.Changeset.change(status: :failed, failure_count: 1, last_error: message)
      |> Mydia.Repo.update!()
    end

    test "the plugin row says how many people it fails for and why", %{conn: conn} do
      seed_plugin("suggester", "Suggester", enabled: true)

      fail_shelf(
        Mydia.AccountsFixtures.user_fixture(),
        "suggester",
        "The model server answered 401"
      )

      fail_shelf(
        Mydia.AccountsFixtures.user_fixture(),
        "suggester",
        "The model server answered 401"
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(
               view,
               "#shelf-failure-note-suggester",
               "Suggestions failing for 2 people: The model server answered 401"
             )
    end

    test "the error text is escaped and clipped", %{conn: conn} do
      seed_plugin("suggester", "Suggester", enabled: true)

      fail_shelf(
        Mydia.AccountsFixtures.user_fixture(),
        "suggester",
        "<script>alert(1)</script>" <> String.duplicate("x", 400)
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      html = view |> element("#shelf-failure-note-suggester") |> render()
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
      assert String.length(html) < 600
    end

    test "a healthy plugin shows no note", %{conn: conn} do
      seed_plugin("suggester", "Suggester", enabled: true)
      Mydia.ShelfHelpers.shelf_fixture(Mydia.AccountsFixtures.user_fixture(), slug: "suggester")

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      refute has_element?(view, "#shelf-failure-note-suggester")
    end
  end

  describe "manifest outgrew its grant (re-approval)" do
    # Seeds an approved, enabled plugin whose stored manifest asks for more than
    # was granted — exactly the state a built-in upgrade leaves behind.
    defp seed_stale_grant(slug, name) do
      manifest =
        Map.put(manifest_map(slug, name), "capabilities", %{
          "events:subscribe" => ["media_item.added", "download.completed"],
          "net:http" => ["discord.com"],
          "data:read" => ["media_item"]
        })

      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: slug,
          name: name,
          version: "1.0.0",
          manifest: manifest,
          wasm_module: guest_wasm(),
          granted_capabilities: %{
            "events:subscribe" => ["media_item.added"],
            "net:http" => ["discord.com"]
          },
          enabled: true
        })

      config
    end

    test "the row is visually distinct and names what it needs", %{conn: conn} do
      seed_stale_grant("notifier", "Notifier")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#reapproval-badge-notifier")
      assert has_element?(view, "#reapproval-note-notifier")

      html = render(view)
      assert html =~ "needs re-approval"
      # Host-owned plain language for the ungranted values, not raw identifiers.
      assert html =~ "finished downloads"
      assert html =~ "Media items"
      refute html =~ "download.completed"
    end

    test "a normally approved plugin carries no re-approval treatment", %{conn: conn} do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{
          "events:subscribe" => ["media_item.added"],
          "net:http" => ["discord.com"]
        }
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      refute has_element?(view, "#reapproval-badge-notifier")
      refute has_element?(view, "#approve-notifier")
    end

    test "re-approving is reachable from the row and grants the requested set", %{conn: conn} do
      seed_stale_grant("notifier", "Notifier")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      # The row keeps its normal lifecycle actions and gains a re-approve action.
      assert has_element?(view, "#toggle-notifier")
      assert has_element?(view, "#approve-notifier")

      view |> element("#approve-notifier") |> render_click()
      assert has_element?(view, "#approval-modal")
      # One grouped list, with only the widened values badged.
      assert has_element?(view, "#approval-reapproval-note", "2 things")
      assert has_element?(view, "#approval-capabilities-group-can_see [data-new]", "Media items")

      assert has_element?(
               view,
               "#approval-capabilities-also [data-new]",
               "also reacts to finished downloads"
             )

      refute has_element?(view, "#approval-capabilities-also [data-new]", "new titles")
      refute has_element?(view, "#approval-capabilities-group-talks_to [data-new]")
      assert has_element?(view, "#confirm-approval", "Re-approve")

      view |> element("#confirm-approval") |> render_click()

      refute has_element?(view, "#approval-modal")
      refute has_element?(view, "#reapproval-badge-notifier")

      config = Settings.get_plugin_config_by_slug("notifier")
      assert config.granted_capabilities["data:read"] == ["media_item"]
      assert "download.completed" in config.granted_capabilities["events:subscribe"]
    end

    test "opening the row's details lists what is requested but not granted", %{conn: conn} do
      seed_stale_grant("notifier", "Notifier")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#details-notifier") |> render_click()

      assert has_element?(view, "#detail-ungranted")
      assert has_element?(view, "#detail-ungranted-capabilities")
      assert has_element?(view, "#detail-ungranted-capabilities-group-can_see", "Media items")
    end

    test "declining leaves the grant untouched", %{conn: conn} do
      seed_stale_grant("notifier", "Notifier")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#approve-notifier") |> render_click()
      view |> element("#decline-approval") |> render_click()

      config = Settings.get_plugin_config_by_slug("notifier")
      refute Map.has_key?(config.granted_capabilities, "data:read")
      assert config.granted_capabilities["events:subscribe"] == ["media_item.added"]
    end
  end

  describe "lifecycle (R14)" do
    test "a bundled plugin has no remove button but can still be disabled", %{conn: conn} do
      seed_from("notifier", "Notifier", "bundled")

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#toggle-notifier")
      refute has_element?(view, "#remove-notifier")
      assert has_element?(view, "#origin-badge-notifier", "Bundled")
    end

    test "a store plugin is removable and its confirm names what goes with it", %{conn: conn} do
      seed_from("notifier", "Notifier", "https://plugins.mydia.dev/notifier-1.0.0.tar")

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#origin-badge-notifier", "Mydia store")

      assert has_element?(
               view,
               ~s(#remove-notifier[data-confirm="Remove Notifier? This also deletes its settings, approvals and suggestions."])
             )
    end

    test "the remove confirm counts a multi-instance plugin's servers" do
      row = %{name: "Plex", multi_instance: true, instances: [%{}, %{}]}

      assert Components.remove_confirm(row) ==
               "Remove Plex? This also deletes its settings, approvals and suggestions, plus 2 configured servers."

      assert Components.remove_confirm(%{row | instances: [%{}]}) =~ "plus 1 configured server."
    end

    test "a sideloaded plugin shows its origin" do
      html =
        render_component(&Components.source_badge/1,
          id: "b",
          origin: :sideloaded,
          source_name: nil
        )

      assert html =~ "Sideloaded"
    end

    test "a third-party plugin's badge names its source" do
      html =
        render_component(&Components.source_badge/1,
          id: "b",
          origin: {:source, "00000000-0000-0000-0000-000000000000"},
          source_name: "Acme plugins"
        )

      assert html =~ "Third-party · Acme plugins"
      assert html =~ "badge-warning"
    end

    test "a plugin awaiting approval can be removed", %{conn: conn} do
      seed_plugin("notifier", "Notifier", [])

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#remove-notifier") |> render_click()

      refute has_element?(view, "#plugin-row-notifier")
      assert Settings.get_plugin_config_by_slug("notifier") == nil
    end

    test "a revoked plugin can be removed", %{conn: conn} do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{"net:http" => ["discord.com"]}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#details-notifier") |> render_click()
      view |> element("#detail-revoke-notifier") |> render_click()

      view |> element("#remove-notifier") |> render_click()

      refute has_element?(view, "#plugin-row-notifier")
      assert Settings.get_plugin_config_by_slug("notifier") == nil
    end

    test "remove deletes the plugin row", %{conn: conn} do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{"net:http" => ["discord.com"]}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#plugin-row-notifier")
      view |> element("#remove-notifier") |> render_click()

      refute has_element?(view, "#plugin-row-notifier")
      assert Settings.get_plugin_config_by_slug("notifier") == nil
    end

    test "an update-available plugin shows the update badge", %{conn: conn} do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{"net:http" => ["discord.com"]}
      )

      {:ok, _} =
        Mydia.Events.create_event(%{
          category: "plugin",
          type: "plugin.update_available",
          actor_type: :system,
          actor_id: "notifier",
          metadata: %{"slug" => "notifier"}
        })

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      assert has_element?(view, "#update-badge-notifier")
    end
  end

  describe "operator settings + host disclosure (U3, U4)" do
    test "a field's hint renders under it, joined with the private-network note on urls",
         %{conn: conn} do
      seed_with_hints("hinted", "Hinted")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#settings-hinted") |> render_click()

      assert has_element?(view, "#plugin-settings-form p", "Users can change it")

      assert has_element?(
               view,
               "#plugin-settings-form p",
               "For example http://ollama.lan:11434 This address may be on your local network."
             )
    end

    test "configuring a host-granting url grants its host (R5, R6)", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier", enabled: true)
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#settings-webhook-notifier")
      view |> element("#settings-webhook-notifier") |> render_click()
      assert has_element?(view, "#plugin-settings-form")

      view
      |> form("#plugin-settings-form", %{
        "target" => "ntfy",
        "webhook_url" => "https://ntfy.example.com/mydia"
      })
      |> render_submit()

      refute has_element?(view, "#settings-modal")

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["webhook_url"] == "https://ntfy.example.com/mydia"
      assert "ntfy.example.com" in config.granted_capabilities["net:http"]
    end

    test "rejects a scheme-less webhook_url instead of silently dropping the grant", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier", enabled: true)
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      html =
        view
        |> form("#plugin-settings-form", %{
          "target" => "ntfy",
          "webhook_url" => "ntfy.example.com/mydia"
        })
        |> render_submit()

      # Modal stays open with an error; nothing is persisted.
      assert has_element?(view, "#settings-modal")
      assert html =~ "full URL"
      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      refute Map.has_key?(config.settings, "webhook_url")
    end

    test "secret values are not echoed back into the form", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier",
        enabled: true,
        settings: %{"ntfy_token" => "tk_supersecret"}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      refute render(view) =~ "tk_supersecret"
    end

    test "a blank secret on save preserves the stored value", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier",
        enabled: true,
        settings: %{"ntfy_token" => "tk_keep", "target" => "ntfy"}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      view
      |> form("#plugin-settings-form", %{
        "webhook_url" => "https://ntfy.example.com/x",
        "ntfy_token" => ""
      })
      |> render_submit()

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["ntfy_token"] == "tk_keep"
    end

    test "the approval modal discloses the host-granting field (U4)", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier", enabled: false, granted: %{})
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#approve-webhook-notifier") |> render_click()

      assert has_element?(
               view,
               "#approval-capabilities-group-talks_to",
               "The server you enter in Webhook / server URL"
             )
    end

    test "a plugin without a settings schema shows a disabled Settings button with a reason",
         %{conn: conn} do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{"net:http" => ["discord.com"]}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      assert has_element?(view, "#plugin-row-notifier")
      # The button is always present (never silently hidden) but disabled here.
      assert has_element?(view, "#settings-notifier[disabled]")
      assert render(view) =~ "no configurable settings"
    end

    test "visible_when hides fields irrelevant to the selected target", %{conn: conn} do
      seed_with_visibility("webhook-notifier", "Webhook Notifier",
        settings: %{
          "target" => "discord",
          "webhook_url" => "https://discord.com/api/webhooks/1/x"
        }
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      # Discord selected: only target + webhook_url show; ntfy/custom fields hidden.
      assert has_element?(view, "#plugin-settings-form select[name=target]")
      assert has_element?(view, "#plugin-settings-form input[name=webhook_url]")
      refute has_element?(view, "#plugin-settings-form input[name=ntfy_tags]")
      refute has_element?(view, "#plugin-settings-form textarea[name=body_template]")

      # Switching the target to custom reveals the custom template fields live.
      view
      |> form("#plugin-settings-form", %{
        "target" => "custom",
        "webhook_url" => "https://discord.com/api/webhooks/1/x"
      })
      |> render_change()

      assert has_element?(view, "#plugin-settings-form textarea[name=body_template]")
      assert has_element?(view, "#plugin-settings-form input[name=query_template]")
      refute has_element?(view, "#plugin-settings-form input[name=ntfy_tags]")
    end

    test "saves a custom target's template fields", %{conn: conn} do
      seed_with_visibility("webhook-notifier", "Webhook Notifier",
        settings: %{"target" => "custom"}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      view
      |> form("#plugin-settings-form", %{
        "target" => "custom",
        "webhook_url" => "https://hooks.example.com/x",
        "body_template" => "{{title}} added",
        "query_template" => "t={{title}}"
      })
      |> render_submit()

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["body_template"] == "{{title}} added"
      assert config.settings["query_template"] == "t={{title}}"
      assert "hooks.example.com" in config.granted_capabilities["net:http"]
    end
  end

  describe "debug logs and test trigger (U6, U7)" do
    alias Mydia.Plugins.Logs

    defp seed_enabled_notifier do
      seed_plugin("notifier", "Notifier",
        enabled: true,
        granted: %{"events:subscribe" => ["media_item.added"]}
      )
    end

    defp log!(attrs) do
      {:ok, log} =
        Logs.create(
          Map.merge(
            %{slug: "notifier", invocation_id: "inv", source: :guest, level: :info, message: "m"},
            attrs
          )
        )

      log
    end

    test "the logs modal renders the activity log with existing rows", %{conn: conn} do
      seed_enabled_notifier()
      log!(%{message: "posting to webhook"})

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#logs-notifier") |> render_click()

      assert has_element?(view, "#plugin-logs")
      assert render(view) =~ "posting to webhook"
    end

    test "the level filter re-queries the timeline", %{conn: conn} do
      seed_enabled_notifier()
      log!(%{level: :debug, message: "debug noise"})
      log!(%{source: :host, level: :error, message: "boom trap"})

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#logs-notifier") |> render_click()
      assert render(view) =~ "debug noise"

      html = view |> form("#log-filter-form") |> render_change(%{"level" => "error"})
      refute html =~ "debug noise"
      assert html =~ "boom trap"
    end

    test "a broadcast log line appends to the open timeline live", %{conn: conn} do
      seed_enabled_notifier()
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#logs-notifier") |> render_click()

      log!(%{invocation_id: "live", message: "live tail line"})

      assert render(view) =~ "live tail line"
    end

    test "the Test control renders for an enabled plugin with subscribed events", %{conn: conn} do
      seed_enabled_notifier()
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#logs-notifier") |> render_click()

      assert has_element?(view, "#test-plugin")
    end

    test "the network tab renders a recorded http_request with method, status and timing",
         %{conn: conn} do
      seed_enabled_notifier()

      {:ok, _event} =
        Mydia.Events.create_event(%{
          category: "plugin",
          type: "plugin.http_request",
          actor_type: :system,
          actor_id: "notifier",
          severity: :info,
          metadata: %{
            "slug" => "notifier",
            "method" => "POST",
            "url" => "https://hooks.example.com/notify?x=1",
            "host" => "hooks.example.com",
            "status" => 200,
            "bytes" => 2048,
            "duration_ms" => 118,
            "outcome" => "ok"
          }
        })

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#logs-notifier") |> render_click()

      html = render(view)
      assert html =~ "hooks.example.com/notify"
      assert html =~ "POST"
      assert html =~ "200"
      assert html =~ "118ms"
    end
  end

  describe "multi-instance plugins" do
    test "lists each instance under the plugin row", %{conn: conn} do
      config = seed_plugin("plex", "Plex", granted: %{"events:subscribe" => []}, enabled: true)

      {:ok, _} =
        Settings.update_plugin_config(config, %{
          manifest: Map.put(config.manifest, "multi_instance", true)
        })

      {:ok, a} = Mydia.Plugins.Instances.create("plex", %{name: "Glass Orchard Server"})
      {:ok, b} = Mydia.Plugins.Instances.create("plex", %{name: "Harbor Lights Server"})

      {:ok, view, _html} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#plugin-instances-plex")
      assert has_element?(view, "#plugin-instances-plex li", a.name)
      assert has_element?(view, "#plugin-instances-plex li", b.name)
    end

    defp seed_multi_instance_with_schema(multi?) do
      config =
        seed_plugin("plex", "Plex", granted: %{"events:subscribe" => []}, enabled: true)

      manifest =
        "plex"
        |> schema_manifest_map("Plex")
        |> Map.put("multi_instance", multi?)

      {:ok, _} = Settings.update_plugin_config(config, %{manifest: manifest})
    end

    test "has no plugin-level settings form and points to Media servers", %{conn: conn} do
      seed_multi_instance_with_schema(true)

      {:ok, view, _html} = live(conn, ~p"/admin/plugins")

      assert has_element?(view, "#settings-plex[disabled]")
      assert render(view) =~ "Configured per server on Media servers"

      render_hook(view, "edit_settings", %{"slug" => "plex"})
      refute has_element?(view, "#settings-modal")
    end

    test "a single-instance plugin with the same schema keeps its settings form", %{conn: conn} do
      seed_multi_instance_with_schema(false)

      {:ok, view, _html} = live(conn, ~p"/admin/plugins")

      refute has_element?(view, "#settings-plex[disabled]")
      view |> element("#settings-plex") |> render_click()
      assert has_element?(view, "#plugin-settings-form")
    end

    test "the detail view does not claim settings can grant hosts", %{conn: conn} do
      seed_multi_instance_with_schema(true)

      {:ok, view, _html} = live(conn, ~p"/admin/plugins")
      view |> element("#details-plex") |> render_click()

      refute render(view) =~ "The server you enter in"
    end

    test "a multi_instance plugin with page writes keeps Settings button enabled", %{conn: conn} do
      config =
        seed_plugin("plex", "Plex",
          granted: %{
            "events:subscribe" => [],
            "surfaces:page" => [],
            "surfaces:write" => ["collections:write"]
          },
          enabled: true
        )

      manifest =
        "plex"
        |> manifest_map("Plex")
        |> Map.put("multi_instance", true)
        |> Map.update!("capabilities", fn caps ->
          Map.merge(caps, %{
            "surfaces:page" => [],
            "surfaces:write" => ["collections:write"]
          })
        end)

      {:ok, _} = Settings.update_plugin_config(config, %{manifest: manifest})

      {:ok, view, _html} = live(conn, ~p"/admin/plugins")

      # Settings button should be enabled (not disabled) because there are page_writes
      # (even though the modal won't open for multi_instance, the button should not be disabled)
      refute has_element?(view, "#settings-plex[disabled]")
      refute render(view) =~ "Configured per server on Media servers"
    end
  end

  describe "page write ceilings and private hosts" do
    defp seed_page_plugin(slug, schema) do
      manifest =
        slug
        |> manifest_map("Page Helper")
        |> Map.update!("capabilities", fn caps ->
          Map.merge(caps, %{
            "surfaces:page" => [],
            "surfaces:write" => ["collections:write"]
          })
        end)
        |> Map.put("settings_schema", schema)

      {:ok, config} =
        Settings.create_plugin_config(%{
          slug: slug,
          name: "Page Helper",
          version: "1.0.0",
          manifest: manifest,
          wasm_module: guest_wasm(),
          granted_capabilities: %{"events:subscribe" => ["media_item.added"]},
          enabled: false
        })

      config
    end

    test "admins save role ceilings from the settings modal", %{conn: conn} do
      seed_page_plugin("page-helper", [])
      guest_before = Mydia.Plugins.Grants.ceiling("page-helper", "guest")
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#settings-page-helper") |> render_click()
      assert has_element?(view, "#plugin-ceilings-form")

      view
      |> form("#plugin-ceilings-form", %{
        "slug" => "page-helper",
        "ceilings" => %{"user" => "session"}
      })
      |> render_submit()

      assert Mydia.Plugins.Grants.ceiling("page-helper", "user") == "session"
      assert Mydia.Plugins.Grants.ceiling("page-helper", "guest") == guest_before
    end

    test "the modal shows the saved values and hides the empty settings form", %{conn: conn} do
      seed_page_plugin("page-helper", [])
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-page-helper") |> render_click()
      refute has_element?(view, "#plugin-settings-form")

      view
      |> form("#plugin-ceilings-form", %{
        "slug" => "page-helper",
        "ceilings" => %{"user" => "always"}
      })
      |> render_submit()

      assert has_element?(
               view,
               "#plugin-ceilings-form select[name='ceilings[user]'] option[selected][value=always]"
             )
    end

    test "malformed or non-page ceilings payloads flash an error", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier", enabled: true)
      seed_page_plugin("page-helper", [])
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      render_click(view, "save_ceilings", %{"bogus" => "x"})
      assert has_element?(view, "#flash-error")

      render_click(view, "save_ceilings", %{
        "slug" => "webhook-notifier",
        "ceilings" => %{"user" => "always"}
      })

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.role_ceilings in [nil, %{}]
    end

    test "a plugin without page writes has no ceilings form", %{conn: conn} do
      seed_with_schema("webhook-notifier", "Webhook Notifier", enabled: true)
      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      view |> element("#settings-webhook-notifier") |> render_click()
      refute has_element?(view, "#plugin-ceilings-form")
    end

    test "a url setting that may be private carries a hint", %{conn: conn} do
      seed_page_plugin("page-helper", [
        %{
          "key" => "server_url",
          "type" => "url",
          "label" => "Server URL",
          "grants_host" => true,
          "allow_private" => true
        }
      ])

      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-page-helper") |> render_click()

      assert has_element?(view, "#plugin-settings-form", "may be on your local network")
    end
  end

  describe "env-declared settings" do
    defp declare_settings(slug, settings) do
      base = Application.get_env(:mydia, :runtime_config) || Mydia.Config.Schema.defaults()
      decl = %Mydia.Config.Schema.PluginSettingsDecl{slug: slug, settings: settings}
      Application.put_env(:mydia, :runtime_config, %{base | plugin_settings: [decl]})
    end

    setup do
      seed_with_schema("webhook-notifier", "Webhook Notifier", [])
      env = %{"webhook_url" => "https://env.example.com/x"}
      declare_settings("webhook-notifier", env)
      Mydia.Plugins.DeclaredSettings.sync("webhook-notifier")
      # Syncing an enabled plugin re-registers it, which reloads :runtime_config
      # from the real environment and drops the injected declaration.
      declare_settings("webhook-notifier", env)
      :ok
    end

    test "render disabled with an ENV badge while other fields stay editable", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      assert has_element?(view, "#plugin-settings-form input[name=webhook_url][disabled]")
      refute has_element?(view, "#plugin-settings-form select[name=target][disabled]")
      assert has_element?(view, "#settings-env-webhook_url")
    end

    test "a save cannot overwrite an env-declared key", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/plugins")
      view |> element("#settings-webhook-notifier") |> render_click()

      view
      |> element("#plugin-settings-form")
      |> render_submit(%{
        "slug" => "webhook-notifier",
        "target" => "ntfy",
        "webhook_url" => "https://other.example.com/x"
      })

      config = Settings.get_plugin_config_by_slug("webhook-notifier")
      assert config.settings["webhook_url"] == "https://env.example.com/x"
      assert config.settings["target"] == "ntfy"
    end
  end

  describe "descriptions" do
    @long_description String.duplicate(
                        "Posts a note to the household channel whenever something lands. ",
                        4
                      )

    test "a store row shows the full description, clamped, with a toggle" do
      browse = %BrowseResult{
        status: :available,
        source_count: 1,
        catalog: [
          %CatalogItem{
            entry: %Entry{
              slug: "notifier",
              name: "Notifier",
              version: "1.0.0",
              description: @long_description,
              package_url: "https://cdn.test/notifier.wasm",
              integrity: "sha256:ab",
              manifest: nil
            },
            state: :not_installed
          }
        ]
      }

      doc =
        render_component(&Components.store_modal/1, browse: browse) |> LazyHTML.from_fragment()

      text =
        doc |> LazyHTML.query("#catalog-description-official-notifier-text") |> LazyHTML.text()

      assert String.trim(text) == String.trim(@long_description)

      refute doc
             |> LazyHTML.query("#catalog-description-official-notifier-toggle")
             |> Enum.empty?()
    end

    test "a short description has no toggle" do
      html = render_component(&Components.plugin_description/1, id: "d", text: "Posts events.")

      doc = LazyHTML.from_fragment(html)
      refute doc |> LazyHTML.query("#d-text") |> Enum.empty?()
      assert doc |> LazyHTML.query("#d-toggle") |> Enum.empty?()
    end

    test "no description renders nothing" do
      html = render_component(&Components.plugin_description/1, id: "d", text: nil)

      assert LazyHTML.from_fragment(html) |> LazyHTML.query("#d") |> Enum.empty?()
    end

    test "an installed row and its details show the description", %{conn: conn} do
      seed_described_plugin("notifier", "Notifier", @long_description,
        granted: %{"net:http" => ["discord.com"]}
      )

      {:ok, view, _} = live(conn, ~p"/admin/plugins")

      assert view |> element("#plugin-description-notifier-text") |> render() =~
               "household channel"

      assert has_element?(view, "#plugin-description-notifier-toggle[phx-click]")

      view |> element("#details-notifier") |> render_click()

      assert view |> element("#detail-modal #detail-description") |> render() =~
               "household channel"
    end
  end
end
