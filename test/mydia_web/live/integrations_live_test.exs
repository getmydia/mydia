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

  test "a multi_instance plugin with no device flow is not offered and gains no instance", %{
    conn: conn
  } do
    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: "media-server-x",
        name: "Media Server X",
        version: "1.0.0",
        enabled: true,
        manifest: %{
          "slug" => "media-server-x",
          "name" => "Media Server X",
          "version" => "1.0.0",
          "multi_instance" => true,
          "capabilities" => %{"users:connections" => []},
          "connection" => %{"type" => "none", "auth_header" => "X-Token: {token}"}
        }
      })

    {:ok, view, _html} = live(conn, ~p"/integrations")

    refute has_element?(view, "#plugin-conn-media-server-x")
    assert Mydia.Plugins.Instances.list("media-server-x") == []
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

  test "lists account links an admin made for this user", %{conn: conn, user: user} do
    {:ok, instance} = Mydia.Plugins.Instances.create("plex", %{name: "Glass Orchard Server"})

    {:ok, [link]} =
      Mydia.Plugins.AccountLinks.replace_user_links(
        instance.id,
        [%{remote_account_id: "42", remote_username: "harbor_kid", user_id: user.id}],
        :admin_mapped
      )

    {:ok, view, _html} = live(conn, ~p"/integrations")

    assert has_element?(view, "#account-links #account-link-#{link.id}", "harbor_kid")
    assert has_element?(view, "#account-link-#{link.id}", "Glass Orchard Server")
  end

  describe "plugin permissions" do
    test "lists grants and revokes one", %{conn: conn, user: user} do
      :ok = Mydia.Plugins.Grants.grant("helper", user.id, "collections:write", "always", "s")
      [grant] = Mydia.Plugins.Grants.list_for_user(user.id)

      {:ok, view, _} = live(conn, ~p"/integrations")
      assert has_element?(view, "#plugin-grant-#{grant.id}")

      view |> element("#revoke-grant-#{grant.id}") |> render_click()
      refute has_element?(view, "#plugin-grant-#{grant.id}")
      assert Mydia.Plugins.Grants.list_for_user(user.id) == []
    end

    test "session grants are not listed", %{conn: conn, user: user} do
      :ok = Mydia.Plugins.Grants.grant("helper", user.id, "collections:write", "session", "s")

      {:ok, view, _} = live(conn, ~p"/integrations")
      refute has_element?(view, "#plugin-permissions")
    end

    test "shows no permissions card without grants", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/integrations")
      refute has_element?(view, "#plugin-permissions")
    end
  end
end
