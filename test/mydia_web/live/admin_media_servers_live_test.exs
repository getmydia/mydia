defmodule MydiaWeb.AdminMediaServersLiveTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

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
      view |> element("#new-media-server") |> render_click()

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

  # A LiveView integration test for the Enabled toggle fix (form="media-server-form"
  # on the Enabled toggle inputs) was attempted here and deleted. Phoenix.LiveViewTest's
  # form/3 collects inputs by walking descendants of the located <form> node; it does
  # not implement HTML5 form-attribute association the way a real browser does, so a
  # submit driven through form/3 never picks up the hidden sentinel or checkbox at all
  # regardless of whether the form="media-server-form" attribute is present. Confirmed
  # empirically: submitting via form/3 against a seeded enabled: true config left
  # updated.enabled == true even with the fix in place, because no "enabled" key ever
  # reached the params. That is a limitation of the test helper, not the fix. The
  # honest pin for this fix lives in components_test.exs ("media server modal, Enabled
  # toggle form association"), which asserts the form= attribute on the rendered markup.

  describe "Empty state and skip reasons" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "renders the empty state with a connect action when nothing is configured",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "#media-servers-empty")
      assert has_element?(view, "#media-servers-empty-cta")
    end

    test "renders a humanized skip reason rather than a raw atom", %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Skipped Plex",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      Mydia.Sync.record_skip(
        %{provider: "plex", provider_instance_id: config.id},
        :seeding_links
      )

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[data-test='last-sync-run']")
      refute render(view) =~ "seeding_links"
    end
  end

  describe "Plex link seeding and Sync Now" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "saving a Plex config enqueues a link seed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("#media-servers-empty-cta")
      |> render_click()

      # The Plex wizard defaults to the OAuth flow, which renders no url/token
      # inputs. Switch to manual entry (a real, existing escape hatch in the
      # wizard) so the form actually has fields to submit.
      view
      |> element("button[phx-click='toggle_plex_manual_entry']")
      |> render_click()

      view
      |> form("#media-server-form", %{
        "media_server_config" => %{
          "name" => "Seeded Plex",
          "type" => "plex",
          "url" => "http://localhost:32400",
          "token" => "tok"
        }
      })
      |> render_submit()

      config = Mydia.Settings.list_media_server_configs() |> List.first()

      assert_enqueued(worker: Mydia.Jobs.PlexLinkSeed, args: %{"config_id" => config.id})
    end

    test "saving a Jellyfin config does not enqueue a link seed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("#media-servers-empty-cta")
      |> render_click()

      # The modal defaults to type "plex", which renders the OAuth wizard
      # instead of url/token inputs. Switch the type to jellyfin first so the
      # form re-renders with the plain url/token fields jellyfin uses.
      view
      |> form("#media-server-form", %{"media_server_config" => %{"type" => "jellyfin"}})
      |> render_change()

      view
      |> form("#media-server-form", %{
        "media_server_config" => %{
          "name" => "Jelly",
          "type" => "jellyfin",
          "url" => "http://localhost:8096",
          "token" => "tok"
        }
      })
      |> render_submit()

      assert [] = all_enqueued(worker: Mydia.Jobs.PlexLinkSeed)
      assert Mydia.Settings.list_media_server_configs() |> List.first()
    end

    test "Sync Now enqueues the server-mode job, not a per-user job", %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Sync Me",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("button[phx-click='sync_watched'][phx-value-id='#{config.id}']")
      |> render_click()

      assert_enqueued(
        worker: Mydia.Jobs.MediaServerWatchedSync,
        args: %{"mode" => "server", "config_id" => config.id}
      )
    end

    test "a Plex server syncing watched status offers profile mapping", %{conn: conn} do
      # Auto-matching links a profile only when its name equals a Mydia
      # username, which on most installs is never, and until this button there
      # was no way for the operator to make the mapping themselves.
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Map Me",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(
               view,
               "button[phx-click='open_plex_profiles'][phx-value-id='#{config.id}']"
             )
    end

    test "a Plex server not syncing watched status does not offer profile mapping",
         %{conn: conn} do
      # Links exist only to keep per-user watch history apart. With sync off
      # there is nothing to keep apart, and offering the mapping would imply a
      # feature the operator never turned on.
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "No Sync",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      refute has_element?(
               view,
               "button[phx-click='open_plex_profiles'][phx-value-id='#{config.id}']"
             )
    end
  end
end
