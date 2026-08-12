defmodule MydiaWeb.AdminMediaServersLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Mydia.Accounts

  setup do
    unique_id = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        email: "admin_#{unique_id}@example.com",
        username: "admin_#{unique_id}",
        password_hash: "$2b$12$test",
        role: "admin"
      })

    {:ok, token, _claims} = Mydia.Auth.Guardian.encode_and_sign(user)

    %{user: user, token: token}
  end

  describe "Authentication" do
    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config/media-servers")
      assert path =~ "/auth"
    end
  end

  describe "Basic Rendering" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")
      %{conn: conn, view: view}
    end

    test "renders the media servers page", %{view: view} do
      html = render(view)
      assert html =~ "Media Servers"
    end
  end

  describe "Watched sync status" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "an enabled sync renders as enabled even though the form stores a string",
         %{conn: conn} do
      {:ok, _config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          # The form posts checkbox values as strings, so this is what is
          # actually stored. The row previously tested `== true` and rendered
          # an enabled sync as disabled, hiding the "Sync Now" button.
          connection_settings: %{"sync_watched" => "true"}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[data-test=watched-sync-enabled]")
      assert has_element?(view, "[phx-click=sync_watched]")
    end

    test "the last run status is shown, including a skip reason", %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok"
        })

      {:ok, _} =
        Mydia.Sync.record_skip(
          %{provider: "plex", provider_instance_id: config.id},
          :sync_disabled
        )

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[data-test=last-sync-run]")
    end

    test "an auth error surfaces a reconnect action", %{conn: conn} do
      {:ok, _config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: "http://localhost:32400",
          token: "stale",
          last_auth_error: "HTTP 401",
          last_auth_error_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[data-test=reconnect-plex]")
    end
  end

  describe "Health status badge" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders a disabled badge for a disabled server", %{conn: conn} do
      {:ok, _config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Off Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: false,
          connection_settings: %{}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[aria-label='Disabled']")
    end

    test "renders an unknown badge for an enabled server that has never been checked",
         %{conn: conn} do
      {:ok, _config} =
        Mydia.Settings.create_media_server_config(%{
          name: "New Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          enabled: true,
          connection_settings: %{}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[aria-label='Unknown']")
    end
  end

  describe "Test connection action" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)
      # The forced check writes through the real ETS cache that `load_data/1`
      # reads right back via `status_map/1`. Without the GenServer running,
      # the cache write is silently rescued away and the badge would read
      # stale "Unknown" instead of the status the flash just reported.
      start_supervised!(Mydia.MediaServer.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      bypass = Bypass.open()
      %{conn: conn, bypass: bypass}
    end

    test "a successful test shows the success flash and flips the badge to Healthy",
         %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/System/Info", fn conn ->
        Plug.Conn.resp(conn, 200, ~s({"Version":"10.9.0"}))
      end)

      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Reachable Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="test_media_server"][phx-value-id="#{config.id}"]})
        |> render_click()

      assert html =~ "Connection to #{config.name} successful!"
      assert has_element?(view, "[aria-label='Healthy']")
    end

    test "a failed test shows the error flash and flips the badge to Unhealthy",
         %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/System/Info", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Unreachable Jellyfin",
          type: :jellyfin,
          url: "http://localhost:#{bypass.port}",
          token: "api-key",
          enabled: true,
          connection_settings: %{}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="test_media_server"][phx-value-id="#{config.id}"]})
        |> render_click()

      assert html =~ "Connection failed"
      assert has_element?(view, "[aria-label='Unhealthy']")
    end
  end

  describe "User mapping" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn, bypass: Bypass.open()}
    end

    test "lists the mappings for a server", %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = jellyfin_server(bypass)

      {:ok, link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "#user-link-#{link.id}")
    end

    test "removing a mapping deletes it", %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = jellyfin_server(bypass)

      {:ok, link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("#user-link-#{link.id} button[phx-click='user_link_delete']")
      |> render_click()

      refute has_element?(view, "#user-link-#{link.id}")
      assert Mydia.Settings.list_media_server_user_links(server.id) == []
    end

    test "saving a Jellyfin mapping stores the account GUID and no token",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "JellyfinTonix"}])

      view = open_mapping_editor(conn, server)

      view
      |> form("#user-link-form", user_link: %{user_id: user.id, remote_user_id: "guid-1"})
      |> render_submit()

      assert [link] = Mydia.Settings.list_media_server_user_links(server.id)
      assert link.user_id == user.id
      assert link.remote_user_id == "guid-1"
      assert link.remote_username == "JellyfinTonix"
      assert link.access_token == nil
    end

    test "an access_token in the submitted form cannot reach the link",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "JellyfinTonix"}])

      view = open_mapping_editor(conn, server)

      view
      |> element("#user-link-form")
      |> render_submit(%{
        "user_link" => %{
          "user_id" => user.id,
          "remote_user_id" => "guid-1",
          "access_token" => "injected-credential"
        }
      })

      assert [link] = Mydia.Settings.list_media_server_user_links(server.id)
      assert link.access_token == nil
    end

    test "a mapping cannot name an account the server did not report",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "JellyfinTonix"}])

      view = open_mapping_editor(conn, server)

      html =
        view
        |> element("#user-link-form")
        |> render_submit(%{
          "user_link" => %{"user_id" => user.id, "remote_user_id" => "guid-made-up"}
        })

      assert html =~ "no longer lists that account"
      assert Mydia.Settings.list_media_server_user_links(server.id) == []
    end

    test "discovering accounts links the ones whose username already matches",
         %{conn: conn, bypass: bypass, user: user} do
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => user.username}])

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="user_link_discover"][phx-value-id="#{server.id}"]})
        |> render_click()

      assert html =~ "Matched 1 account"
      assert [link] = Mydia.Settings.list_media_server_user_links(server.id)
      assert link.remote_user_id == "guid-1"
    end

    test "a server that cannot be read surfaces the reason instead of an editor",
         %{conn: conn, bypass: bypass} do
      server = jellyfin_server(bypass)

      Bypass.stub(bypass, "GET", "/Users", fn conn ->
        Plug.Conn.resp(conn, 401, "")
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="user_link_new"][phx-value-id="#{server.id}"]})
        |> render_click()

      assert html =~ "Could not read accounts from"
      refute has_element?(view, "#user-link-form")
    end
  end

  describe "Plex wizard auto-connect" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")
      %{view: view}
    end

    test "the modal no longer offers a Connection step", %{view: view} do
      view |> element("[phx-click='new_media_server']") |> render_click()

      refute has_element?(view, "li.step", "Connection")
      assert has_element?(view, "li.step", "Server")
    end
  end

  defp jellyfin_server(bypass) do
    {:ok, server} =
      Mydia.Settings.create_media_server_config(%{
        name: "Jellyfin",
        type: :jellyfin,
        url: "http://127.0.0.1:#{bypass.port}",
        token: "api-key",
        enabled: true,
        connection_settings: %{}
      })

    server
  end

  # Req only decodes a body the response declares as JSON.
  defp stub_jellyfin_users(bypass, users) do
    Bypass.stub(bypass, "GET", "/Users", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(users))
    end)
  end

  defp open_mapping_editor(conn, server) do
    {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

    view
    |> element(~s{[phx-click="user_link_new"][phx-value-id="#{server.id}"]})
    |> render_click()

    assert has_element?(view, "#user-link-form")

    view
  end
end
