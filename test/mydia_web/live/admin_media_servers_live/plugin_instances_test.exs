defmodule MydiaWeb.AdminMediaServersLive.PluginInstancesTest do
  # async: false: connected LiveView under the Postgres sandbox, plus the
  # app-wide plugin Registry.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry

  @slug "plex"

  setup %{conn: conn} do
    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Plex",
        category: "media_server",
        multi_instance: true,
        setup: true,
        enabled: true
      })

    on_exit(fn -> Registry.unregister(@slug) end)
    # Not started in test (gated by :start_health_monitors, Task 8); no boot
    # checks, which would touch the DB from unsupervised tasks.
    start_supervised!({Mydia.Plugins.InstanceHealth, check_on_start: false})

    {:ok, instance} =
      Instances.create(@slug, %{
        name: "Glass Orchard Server",
        approved_endpoints: [%{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400}]
      })

    {conn, _user} = register_and_log_in_user(conn, %{role: "admin"})
    {:ok, view, _html} = live(conn, ~p"/admin/media-servers")

    %{view: view, instance: instance}
  end

  test "renders a card for each media server plugin instance", %{view: view, instance: i} do
    assert has_element?(view, "#plugin-instances #plugin-instance-#{i.id}")
  end

  test "the add-server menu offers Jellyfin and each media server plugin", %{view: view} do
    assert has_element?(view, "#add-server-menu #new-media-server")
    assert has_element?(view, "#add-server-menu #add-server-plugin-#{@slug}")
  end

  test "adding a plugin server opens the setup modal", %{view: view} do
    view |> element("#add-server-plugin-#{@slug}") |> render_click()
    assert has_element?(view, "#plugin-setup-modal")
  end

  test "reconnect and accounts open the setup modal", %{view: view, instance: i} do
    view |> element("#plugin-instance-reconnect-#{i.id}") |> render_click()
    assert has_element?(view, "#plugin-setup-modal")

    send(
      view.pid,
      {MydiaWeb.PluginSetupLive.Modal, :closed,
       %{id: "plugin-setup-modal", status: :cancelled, instance_id: i.id}}
    )

    refute has_element?(view, "#plugin-setup-modal")

    view |> element("#plugin-instance-accounts-#{i.id}") |> render_click()
    assert has_element?(view, "#plugin-setup-modal")
  end

  test "a finished setup closes the modal and reloads the cards", %{view: view} do
    view |> element("#add-server-plugin-#{@slug}") |> render_click()
    {:ok, other} = Instances.create(@slug, %{name: "Harbor Lights Server"})

    send(
      view.pid,
      {MydiaWeb.PluginSetupLive.Modal, :closed,
       %{id: "plugin-setup-modal", status: :done, instance_id: other.id}}
    )

    refute has_element?(view, "#plugin-setup-modal")
    assert has_element?(view, "#plugin-instance-#{other.id}")
    assert render(view) =~ "Server saved"
  end

  test "a runtime instance cannot be toggled or deleted from the page", %{view: view} do
    {:ok, runtime} =
      Instances.create(@slug, %{name: "Declared Server", runtime_key: "Declared Server"})

    render_click(view, "plugin_instance_delete", %{"id" => runtime.id})
    assert Instances.get(runtime.id)

    render_click(view, "plugin_instance_toggle", %{"id" => runtime.id})
    assert Instances.get(runtime.id).enabled
  end

  test "toggle disables the instance", %{view: view, instance: i} do
    view |> element("#plugin-instance-toggle-#{i.id}") |> render_click()
    refute Instances.get(i.id).enabled
  end

  test "delete removes the instance", %{view: view, instance: i} do
    view |> element("#plugin-instance-delete-#{i.id}") |> render_click()
    assert Instances.get(i.id) == nil
    refute has_element?(view, "#plugin-instance-#{i.id}")
  end

  test "removing an endpoint drops it from the allowlist", %{view: view, instance: i} do
    view |> element("#plugin-instance-endpoint-remove-#{i.id}-0") |> render_click()
    assert Instances.get(i.id).approved_endpoints == []
  end

  test "malformed remove-endpoint params neither crash nor remove anything", %{
    view: view,
    instance: i
  } do
    render_click(view, "plugin_instance_remove_endpoint", %{
      "id" => i.id,
      "scheme" => "http",
      "host" => "10.9.9.9",
      "port" => "abc"
    })

    assert length(Instances.get(i.id).approved_endpoints) == 1
  end

  test "a finished connection test leaves an open Jellyfin modal alone", %{
    view: view,
    instance: i
  } do
    view |> element("#new-media-server") |> render_click()
    assert has_element?(view, "#media-server-modal")

    send(view.pid, {:plugin_instance_tested, i.id})
    render(view)

    assert has_element?(view, "#media-server-modal")
  end

  test "the add-server menu skips a plugin that is disabled", %{view: view, instance: i} do
    {:ok, _} =
      Registry.register("shelf", %Plugin{
        slug: "shelf",
        name: "Shelf",
        category: "media_server",
        setup: true,
        enabled: false
      })

    on_exit(fn -> Registry.unregister("shelf") end)

    send(view.pid, {:plugin_instance_tested, i.id})
    render(view)

    assert has_element?(view, "#add-server-plugin-#{@slug}")
    refute has_element?(view, "#add-server-plugin-shelf")
  end

  test "sync now starts a run off the LiveView process", %{view: view, instance: i} do
    html = view |> element("#plugin-instance-sync-#{i.id}") |> render_click()
    assert html =~ "Sync started for Glass Orchard Server"
  end
end
