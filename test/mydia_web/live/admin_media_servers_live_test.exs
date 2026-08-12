defmodule MydiaWeb.AdminMediaServersLiveTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  alias Mydia.Accounts
  alias Mydia.Jobs.MediaServerWatchedSync

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

    test "a skipped run shows a human readable reason, not the raw run status",
         %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key",
          connection_settings: %{}
        })

      {:ok, _run} =
        Mydia.Sync.record_skip(
          %{provider: "jellyfin", provider_instance_id: config.id, user_id: nil},
          :no_user_mapping
        )

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "#sync-skip-#{config.id}")
      assert render(view) =~ "Press Accounts to map them."
      refute has_element?(view, "#sync-error-#{config.id}")
    end

    test "an errored run shows its error message, distinct from a skip",
         %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key"
        })

      {:ok, run} =
        Mydia.Sync.start_run(%{
          provider: "jellyfin",
          provider_instance_id: config.id,
          user_id: nil,
          direction: :bidirectional
        })

      {:ok, _run} = Mydia.Sync.finish_run(run, :error, %{}, "connection refused")

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "#sync-error-#{config.id}")
      assert render(view) =~ "connection refused"
      refute has_element?(view, "#sync-skip-#{config.id}")
    end

    test "a successful run shows neither a skip nor an error line", %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key"
        })

      {:ok, run} =
        Mydia.Sync.start_run(%{
          provider: "jellyfin",
          provider_instance_id: config.id,
          user_id: nil,
          direction: :bidirectional
        })

      {:ok, _run} = Mydia.Sync.finish_run(run, :ok, %{imported: 2, exported: 1}, nil)

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "[data-test=last-sync-run]")
      assert render(view) =~ "Synced 2 in, 1 out"
      refute has_element?(view, "#sync-skip-#{config.id}")
      refute has_element?(view, "#sync-error-#{config.id}")
    end

    test "an unrecognised skip reason falls back to the raw string instead of crashing",
         %{conn: conn} do
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Jellyfin",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key"
        })

      {:ok, _run} =
        Mydia.Sync.record_skip(
          %{provider: "jellyfin", provider_instance_id: config.id, user_id: nil},
          :some_future_reason
        )

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      assert has_element?(view, "#sync-skip-#{config.id}")
      assert render(view) =~ "some_future_reason"
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

  describe "Account mapping" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn, bypass: Bypass.open()}
    end

    test "the modal lists the server's accounts and suggests the username match",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Nobody"}
      ])

      view = open_account_mapping(conn, server)

      assert has_element?(view, "#account-guid-1")
      assert has_element?(view, "#account-guid-2")

      # A name match is a suggestion, not a link: nothing is written until Save.
      assert has_element?(view, ~s{#account-select-guid-1 option[value="#{user.id}"][selected]})
      assert Mydia.Settings.list_media_server_user_links(server.id) == []
    end

    test "saving a Jellyfin mapping stores the account GUID and no token",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "Tonix"}])

      conn
      |> open_account_mapping(server)
      |> form("#account-mapping-form", mapping: %{"guid-1" => user.id})
      |> render_submit()

      assert [link] = wait_for_links(server)
      assert link.user_id == user.id
      assert link.remote_user_id == "guid-1"
      assert link.remote_username == "Tonix"
      # Jellyfin issues no per-user tokens; a token here could only be another
      # account's, and the sync would then read the wrong history.
      assert is_nil(link.access_token)
    end

    test "a mapping cannot name an account the server did not report",
         %{conn: conn, bypass: bypass} do
      # The picker's own list is the whitelist. A crafted submit naming an
      # account this server never listed writes nothing at all.
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "Tonix"}])

      view = open_account_mapping(conn, server)

      view
      |> element("#account-mapping-form")
      |> render_submit(%{"mapping" => %{"guid-1" => "", "guid-forged" => user.id}})

      assert eventually(fn -> render(view) =~ "No accounts are linked" end)
      assert Mydia.Settings.list_media_server_user_links(server.id) == []
    end

    test "an access_token in the submitted form cannot reach the link",
         %{conn: conn, bypass: bypass} do
      # Nothing in the payload is cast onto the row: every column comes from the
      # config, the picked user, and the account the server itself reported.
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "Tonix"}])

      view = open_account_mapping(conn, server)

      view
      |> element("#account-mapping-form")
      |> render_submit(%{
        "mapping" => %{"guid-1" => user.id},
        "access_token" => "stolen-token"
      })

      assert [link] = wait_for_links(server)
      assert is_nil(link.access_token)
    end

    test "unmapping an account removes its link", %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "Tonix"}])

      {:ok, _link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: true
        })

      conn
      |> open_account_mapping(server)
      |> form("#account-mapping-form", mapping: %{"guid-1" => ""})
      |> render_submit()

      assert eventually(fn -> Mydia.Settings.list_media_server_user_links(server.id) == [] end)
    end

    test "two accounts on one Mydia user is refused and writes nothing",
         %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})
      server = sync_enabled_server(bypass)

      stub_jellyfin_users(bypass, [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Other"}
      ])

      view = open_account_mapping(conn, server)

      view
      |> form("#account-mapping-form", mapping: %{"guid-1" => user.id, "guid-2" => user.id})
      |> render_submit()

      assert eventually(fn -> render(view) =~ "only one" end)
      assert Mydia.Settings.list_media_server_user_links(server.id) == []
    end

    test "a server that cannot be read surfaces the reason instead of a form",
         %{conn: conn, bypass: bypass} do
      server = sync_enabled_server(bypass)
      Bypass.down(bypass)

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element(~s{[phx-click="open_account_mapping"][phx-value-id="#{server.id}"]})
      |> render_click()

      assert eventually(fn -> has_element?(view, "#account-mapping-error") end, 600)
      refute has_element?(view, "#account-mapping-form")
    end
  end

  describe "Sync now" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn, bypass: Bypass.open()}
    end

    test "a user with no mapping on that server produces no per-user job",
         %{conn: conn, bypass: bypass} do
      # Enqueueing a per-user job without a link resolved the sync's scope to the
      # server's own token, so pressing this imported the server owner's watch
      # history into the pressing user's account and exported back into the
      # owner's. Server mode closes that by only ever fanning out off link rows.
      server = sync_enabled_server(bypass)

      click_sync_now(conn, server)
      assert per_user_jobs() == []

      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "mode" => "server",
                 "config_id" => server.id
               })

      assert per_user_jobs() == []
      assert Mydia.Sync.last_run("jellyfin", server.id).skip_reason == "seeding_links"
    end

    test "a mapped user gets exactly one job carrying their own link",
         %{conn: conn, bypass: bypass, user: user} do
      server = sync_enabled_server(bypass)

      {:ok, link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: true
        })

      click_sync_now(conn, server)

      assert :ok =
               perform_job(MediaServerWatchedSync, %{
                 "mode" => "server",
                 "config_id" => server.id
               })

      assert [job] = per_user_jobs()
      assert job.args["config_id"] == server.id
      assert job.args["user_id"] == user.id
      assert job.args["link_id"] == link.id
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

      assert_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed, args: %{"config_id" => config.id})
    end

    test "saving a server whose mappings were all deleted does not seed them back",
         %{conn: conn} do
      # Deleting a mapping promises watched sync will skip that user until it is
      # mapped again. Every Plex save enqueues a seed, and flipping a sync
      # direction is a save, so an ungated seed-on-save put the mappings back by
      # a different route than the scheduler tick already guarded.
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Seeded Already",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{
            "sync_watched" => true,
            "plex_links_seeded_at" => "2026-08-01T00:00:00Z"
          }
        })

      assert Mydia.Settings.list_media_server_user_links(config.id) == []

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view |> element("[phx-click='edit_media_server']") |> render_click()

      view
      |> form("#media-server-form", %{
        "media_server_config" => %{
          "name" => "Seeded Already",
          "type" => "plex",
          "url" => "http://localhost:32400",
          "token" => "tok"
        }
      })
      |> render_submit()

      assert [] = all_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed)
      assert Mydia.Settings.list_media_server_user_links(config.id) == []
    end

    test "saving a server that has never been seeded still enqueues a seed", %{conn: conn} do
      # The other side of the gate: a Plex server with no stamp and no mappings
      # is a first run, and must still be filled in automatically.
      {:ok, config} =
        Mydia.Settings.create_media_server_config(%{
          name: "Never Seeded",
          type: :plex,
          url: "http://localhost:32400",
          token: "tok",
          enabled: true,
          connection_settings: %{"sync_watched" => true}
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view |> element("[phx-click='edit_media_server']") |> render_click()

      view
      |> form("#media-server-form", %{
        "media_server_config" => %{
          "name" => "Never Seeded",
          "type" => "plex",
          "url" => "http://localhost:32400",
          "token" => "tok"
        }
      })
      |> render_submit()

      assert_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed, args: %{"config_id" => config.id})
    end

    test "saving a Jellyfin config enqueues a link seed too", %{conn: conn} do
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

      # Jellyfin seeds by username match the same way Plex does. The worker
      # itself is the gate on watched sync being on, so the save enqueues it
      # either way and a server that never opted in is a cheap no-op.
      assert [_seed] = all_enqueued(worker: Mydia.Jobs.MediaServerLinkSeed)
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
               "button[phx-click='open_account_mapping'][phx-value-id='#{config.id}']"
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
               "button[phx-click='open_account_mapping'][phx-value-id='#{config.id}']"
             )
    end
  end

  # The Sync Now button enqueues one server-mode job and nothing else. The
  # per-user jobs are produced by that job's own fan-out, off the link rows, so
  # the tests click and then run the queued job rather than asserting on the
  # click alone. The invariant is unchanged from when the button resolved a link
  # itself: no job may ever carry a user without also carrying the link that says
  # which remote account that user is.
  defp click_sync_now(conn, server) do
    {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

    html =
      view
      |> element(~s{[phx-click="sync_watched"][phx-value-id="#{server.id}"]})
      |> render_click()

    assert_enqueued(
      worker: MediaServerWatchedSync,
      args: %{"mode" => "server", "config_id" => server.id}
    )

    html
  end

  defp per_user_jobs do
    all_enqueued(worker: MediaServerWatchedSync) |> Enum.reject(& &1.args["mode"])
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

  # Jellyfin rather than Plex on purpose: the Sync Now button used to be gated
  # on `type == :plex` while the settings toggle offered watched sync to both,
  # so a Jellyfin operator could enable it and had no way to run it.
  defp sync_enabled_server(bypass) do
    {:ok, server} =
      Mydia.Settings.create_media_server_config(%{
        name: "Jellyfin",
        type: :jellyfin,
        url: "http://127.0.0.1:#{bypass.port}",
        token: "api-key",
        enabled: true,
        connection_settings: %{"sync_watched" => "true"}
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

  # The account list is fetched off the LiveView process, so the modal renders
  # its loading state first and the form only once the answer lands.
  defp open_account_mapping(conn, server) do
    {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

    view
    |> element(~s{[phx-click="open_account_mapping"][phx-value-id="#{server.id}"]})
    |> render_click()

    assert eventually(fn -> has_element?(view, "#account-mapping-form") end)

    view
  end

  # Saving also runs off the LiveView process, so the row lands a moment after
  # render_submit/1 returns.
  defp wait_for_links(server) do
    assert eventually(fn -> Mydia.Settings.list_media_server_user_links(server.id) != [] end)
    Mydia.Settings.list_media_server_user_links(server.id)
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, attempts - 1)
    end
  end
end
