defmodule MydiaWeb.IntegrationsLiveTest do
  # async: false — connected LiveView under the Postgres sandbox (rows inserted
  # in the test must be visible to the mount process).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Plugins.Connections
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Settings

  @slug "simkl_sync"

  defp connectable_descriptor do
    %{
      "type" => "oauth_device",
      "code_url" => "https://api.simkl.com/oauth/pin?client_id={client_id}",
      "poll_url" => "https://api.simkl.com/oauth/pin/{user_code}?client_id={client_id}",
      "verification_url" => "https://simkl.com/pin",
      "client_id" => "embedded-id"
    }
  end

  defp install_connectable! do
    manifest = %{
      "slug" => @slug,
      "name" => "Simkl Sync",
      "version" => "1.0.0",
      "capabilities" => %{
        "events:subscribe" => ["playback.finished"],
        "net:http" => ["api.simkl.com", "simkl.com"],
        "users:connections" => []
      },
      "connection" => connectable_descriptor()
    }

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: @slug,
        name: "Simkl Sync",
        version: "1.0.0",
        source_url: "test",
        manifest: manifest,
        granted_capabilities: %{
          "net:http" => ["api.simkl.com", "simkl.com"],
          "users:connections" => []
        },
        enabled: true
      })

    {:ok, _} =
      Registry.register(@slug, %Plugin{
        slug: @slug,
        name: "Simkl Sync",
        granted_capabilities: %{"net:http" => ["api.simkl.com", "simkl.com"]},
        enabled: true
      })

    on_exit(fn -> Registry.unregister(@slug) end)
    :ok
  end

  setup %{conn: conn} do
    install_connectable!()
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "mounts and offers the plugin connection action", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#plugin-conn-#{@slug}")
  end

  test "exposes an Integrations link in the sidebar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "a[href='/integrations']")
  end

  test "renders a connect card for an installed connectable plugin", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#plugin-conn-#{@slug}")
    assert has_element?(view, "#plugin-conn-connect-#{@slug}")
    # The consent copy names the plugin and its reach.
    assert render(view) =~ "mark items watched in mydia on your behalf"
  end

  test "shows the connected state and disconnects (F1/AE3: session user only)", %{
    conn: conn,
    user: user
  } do
    {:ok, _} =
      Connections.connect(@slug, user.id, %{access_token: "tok", external_username: "alice"})

    {:ok, view, _html} = live(conn, ~p"/integrations")
    assert has_element?(view, "#plugin-conn-connected-#{@slug}")

    view
    |> element("button[phx-click='plugin_disconnect'][phx-value-slug='#{@slug}']")
    |> render_click()

    # The connection is gone and the card returns to the connect state.
    assert Connections.get(@slug, user.id) == nil
    assert has_element?(view, "#plugin-conn-connect-#{@slug}")
  end

  test "an errored connection offers reconnect", %{conn: conn, user: user} do
    {:ok, _} = Connections.connect(@slug, user.id, %{access_token: "tok", status: "error"})

    {:ok, view, _html} = live(conn, ~p"/integrations")
    assert has_element?(view, "#plugin-conn-errored-#{@slug}")
  end
end
