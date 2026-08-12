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
      assert render(view) =~ "User mapping section below"
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

    test "discovering leaves a hand-made mapping alone and says so",
         %{conn: conn, bypass: bypass} do
      # The operator mapped alex to guid-2 because the usernames differ. Jellyfin
      # also has an account named after another Mydia user, sarah. Discovering
      # must not write sarah -> guid-2 on top of it: both users would then import
      # guid-2's watch history.
      alex = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})
      Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-2", "Name" => "sarah"}])

      {:ok, hand_made} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: alex.id,
          remote_user_id: "guid-2",
          remote_username: "sarah",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="user_link_discover"][phx-value-id="#{server.id}"]})
        |> render_click()

      assert html =~ "Left 1 existing mapping alone"

      assert [kept] = Mydia.Settings.list_media_server_user_links(server.id)
      assert kept.id == hand_made.id
      assert kept.user_id == alex.id
    end

    test "editing a mapping onto a different Mydia user moves it",
         %{conn: conn, bypass: bypass} do
      alex = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})
      sarah = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "Tonix"}])

      {:ok, link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: alex.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("#user-link-#{link.id} button[phx-click='user_link_edit']")
      |> render_click()

      view
      |> form("#user-link-form", user_link: %{user_id: sarah.id, remote_user_id: "guid-1"})
      |> render_submit()

      assert [moved] = Mydia.Settings.list_media_server_user_links(server.id)
      assert moved.user_id == sarah.id
      assert moved.remote_user_id == "guid-1"
      refute moved.user_id == alex.id
    end

    test "editing a mapping onto a user who already has one is refused, not collapsed",
         %{conn: conn, bypass: bypass} do
      # alex -> guid-1 edited onto sarah, who already holds sarah -> guid-2.
      # This used to delete alex's row and overwrite sarah's, leaving one
      # mapping where there had been two and saying nothing about it.
      alex = Mydia.AccountsFixtures.user_fixture(%{username: "alex"})
      sarah = Mydia.AccountsFixtures.user_fixture(%{username: "sarah"})
      server = jellyfin_server(bypass)

      stub_jellyfin_users(bypass, [
        %{"Id" => "guid-1", "Name" => "One"},
        %{"Id" => "guid-2", "Name" => "Two"}
      ])

      {:ok, alex_link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: alex.id,
          remote_user_id: "guid-1",
          remote_username: "One",
          enabled: true
        })

      {:ok, sarah_link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: sarah.id,
          remote_user_id: "guid-2",
          remote_username: "Two",
          enabled: true
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element("#user-link-#{alex_link.id} button[phx-click='user_link_edit']")
      |> render_click()

      html =
        view
        |> form("#user-link-form", user_link: %{user_id: sarah.id, remote_user_id: "guid-1"})
        |> render_submit()

      assert html =~ "already has a mapping"

      links = Mydia.Settings.list_media_server_user_links(server.id)
      assert length(links) == 2
      assert Enum.find(links, &(&1.id == alex_link.id)).user_id == alex.id
      assert Enum.find(links, &(&1.id == sarah_link.id)).remote_user_id == "guid-2"
    end

    test "a failed save keeps what was already chosen", %{conn: conn, bypass: bypass} do
      user = Mydia.AccountsFixtures.user_fixture(%{username: "zzz-last"})
      server = jellyfin_server(bypass)
      stub_jellyfin_users(bypass, [%{"Id" => "guid-1", "Name" => "JellyfinTonix"}])

      view = open_mapping_editor(conn, server)

      view
      |> element("#user-link-form")
      |> render_submit(%{
        "user_link" => %{"user_id" => user.id, "remote_user_id" => "guid-made-up"}
      })

      assert has_element?(
               view,
               ~s{select#user_link_user_id option[value="#{user.id}"][selected]}
             )
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

    test "a user with no mapping on that server enqueues nothing",
         %{conn: conn, bypass: bypass} do
      # Enqueueing without a link resolved the sync's scope to the server's own
      # token, so pressing this imported the server owner's watch history into
      # the pressing user's account and exported back into the owner's.
      server = sync_enabled_server(bypass)

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="sync_watched"][phx-value-id="#{server.id}"]})
        |> render_click()

      assert html =~ "not mapped to an account"
      assert all_enqueued(worker: MediaServerWatchedSync) == []
    end

    test "a mapped user enqueues exactly one job carrying their own link",
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

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      view
      |> element(~s{[phx-click="sync_watched"][phx-value-id="#{server.id}"]})
      |> render_click()

      assert [job] = all_enqueued(worker: MediaServerWatchedSync)
      assert job.args["config_id"] == server.id
      assert job.args["user_id"] == user.id
      assert job.args["link_id"] == link.id
    end

    test "a paused mapping enqueues nothing", %{conn: conn, bypass: bypass, user: user} do
      server = sync_enabled_server(bypass)

      {:ok, _link} =
        Mydia.Settings.upsert_media_server_user_link(%{
          media_server_config_id: server.id,
          user_id: user.id,
          remote_user_id: "guid-1",
          remote_username: "Tonix",
          enabled: false
        })

      {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

      html =
        view
        |> element(~s{[phx-click="sync_watched"][phx-value-id="#{server.id}"]})
        |> render_click()

      assert html =~ "is paused"
      assert all_enqueued(worker: MediaServerWatchedSync) == []
    end
  end

  describe "Pausing a mapping" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn, bypass: Bypass.open()}
    end

    test "the toggle pauses a mapping and resumes it again", %{conn: conn, bypass: bypass} do
      # Nothing in the UI could set enabled to false, so the Paused badge the
      # row already rendered was a branch no operator could reach.
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
      |> element("#user-link-#{link.id} button[phx-click='user_link_toggle']")
      |> render_click()

      refute Mydia.Settings.get_media_server_user_link!(link.id).enabled
      assert has_element?(view, "#user-link-#{link.id}", "Paused")

      view
      |> element("#user-link-#{link.id} button[phx-click='user_link_toggle']")
      |> render_click()

      assert Mydia.Settings.get_media_server_user_link!(link.id).enabled
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

  defp open_mapping_editor(conn, server) do
    {:ok, view, _html} = live(conn, ~p"/admin/config/media-servers")

    view
    |> element(~s{[phx-click="user_link_new"][phx-value-id="#{server.id}"]})
    |> render_click()

    assert has_element?(view, "#user-link-form")

    view
  end
end
