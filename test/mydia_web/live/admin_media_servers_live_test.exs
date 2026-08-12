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

  # Characterization test, not a regression test: pre-branch, edit-mode save
  # already used `editing_media_server` as the changeset base, so
  # `machine_identifier` and `connections` already survived a form-params-only
  # save. What actually blocked editing a wizard-created server was the
  # browser-level `required` attribute on the URL input, which `render_submit/1`
  # does not enforce; that blockage is pinned separately in
  # `components_test.exs` ("media server modal, Server URL requirement").
  describe "discovery data on a Plex wizard config survives a form-params-only save" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      # A wizard-created config: no url, addressable only through discovery.
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Storage",
          type: :plex,
          url: nil,
          token: "acct-token",
          machine_identifier: "machine-abc",
          connections: [%{"uri" => "http://127.0.0.1:32400", "local" => true}]
        })

      %{conn: conn, config: config}
    end

    test "renaming via form params alone preserves machine_identifier and connections",
         %{conn: conn, config: config} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view |> element("[phx-click='edit_media_server']") |> render_click()

      view
      |> form("#media-server-form", %{
        "media_server_config" => %{
          "name" => "Renamed",
          "type" => "plex",
          "url" => "",
          "token" => "acct-token"
        }
      })
      |> render_submit()

      updated = Mydia.Settings.get_media_server_config!(config.id)

      assert updated.name == "Renamed"
      # Discovery data must survive a save driven purely by form params.
      assert updated.machine_identifier == "machine-abc"
      assert [%{"uri" => "http://127.0.0.1:32400"}] = updated.connections
    end
  end
end
