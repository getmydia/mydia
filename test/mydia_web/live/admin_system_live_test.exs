defmodule MydiaWeb.AdminSystemLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Mydia.Accounts
  alias Mydia.Library.MediaFile
  alias Mydia.Repo

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
    setup do
      start_supervised!(Mydia.Indexers.Health)
      :ok
    end

    test "redirects unauthenticated users", %{conn: conn} do
      {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/config")
      assert path =~ "/auth"
    end

    test "requires admin role", %{conn: conn, token: _token} do
      {:ok, regular_user} =
        Accounts.create_user(%{
          email: "user@example.com",
          username: "user",
          password_hash: "$2b$12$test",
          role: "user"
        })

      {:ok, regular_token, _claims} = Mydia.Auth.Guardian.encode_and_sign(regular_user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:guardian_default_token, regular_token)
        |> put_req_header("authorization", "Bearer #{regular_token}")

      conn = get(conn, ~p"/admin/config")
      assert redirected_to(conn) == "/"
    end

    test "allows admin access", %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, _view, html} = live(conn, ~p"/admin/config")
      assert html =~ "Configuration"
    end
  end

  describe "Redirects" do
    setup %{conn: conn, token: token} do
      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "/admin redirects to /admin/config", %{conn: conn} do
      conn = get(conn, ~p"/admin")
      assert redirected_to(conn) == "/admin/config"
    end

    test "/admin/status redirects to /admin/config", %{conn: conn} do
      conn = get(conn, ~p"/admin/status")
      assert redirected_to(conn) == "/admin/config"
    end
  end

  describe "System Status Tab" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config")
      %{conn: conn, view: view}
    end

    test "renders system status tab by default", %{view: view} do
      assert has_element?(view, ~s{a[class*="tab-active"]}, "Status")
    end

    test "displays system information", %{view: view} do
      assert has_element?(view, "h3", "System")
      assert has_element?(view, ".stat-title", "Version")
      assert has_element?(view, ".stat-title", "Elixir")
      assert has_element?(view, ".stat-title", "Memory")
      assert has_element?(view, ".stat-title", "Uptime")
    end

    test "displays database information", %{view: view} do
      assert has_element?(view, "h3", "Database")
    end

    test "no longer renders the FlareSolverr External Services card", %{view: view} do
      html = render(view)
      refute html =~ "External Services"
      refute html =~ "FlareSolverr"
    end

    test "displays database adapter-specific information", %{view: view} do
      html = render(view)

      if Mydia.DB.postgres?() do
        assert html =~ "PostgreSQL"
      else
        assert html =~ "SQLite"
      end
    end
  end

  describe "Stuck upgrade health check" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      %{conn: conn}
    end

    test "stays quiet when nothing is stuck mid-upgrade", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/config")

      refute has_element?(view, "#stuck-upgrades-alert")
    end

    test "surfaces stuck upgrades and points at the jobs page", %{conn: conn} do
      superseded = insert(:media_file)
      stuck = insert(:media_file, supersedes_media_file_id: superseded.id)
      backdate!(stuck, hours: 2)

      {:ok, view, _html} = live(conn, ~p"/admin/config")

      assert has_element?(view, "#stuck-upgrades-alert")
      assert has_element?(view, ~s{#stuck-upgrades-alert a[href="/admin/jobs"]})
    end
  end

  describe "Tab Navigation" do
    setup %{conn: conn, token: token} do
      start_supervised!(Mydia.Indexers.Health)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:guardian_default_token, token)
        |> put_req_header("authorization", "Bearer #{token}")

      {:ok, view, _html} = live(conn, ~p"/admin/config")
      %{conn: conn, view: view}
    end

    test "renders tab navigation links", %{view: view} do
      assert has_element?(view, ~s{a[role="tab"]}, "Status")
      assert has_element?(view, ~s{a[role="tab"]}, "Settings")
      assert has_element?(view, ~s{a[role="tab"]}, "Quality")
      assert has_element?(view, ~s{a[role="tab"]}, "Clients")
      assert has_element?(view, ~s{a[role="tab"]}, "Indexers")
      assert has_element?(view, ~s{a[role="tab"]}, "Library")
      assert has_element?(view, ~s{a[role="tab"]}, "Media Servers")
    end

    test "tab links point to correct routes", %{view: view} do
      html = render(view)
      assert html =~ ~s{href="/admin/config/settings"}
      assert html =~ ~s{href="/admin/config/quality"}
      assert html =~ ~s{href="/admin/config/clients"}
      assert html =~ ~s{href="/admin/config/indexers"}
      assert html =~ ~s{href="/admin/config/library-paths"}
      assert html =~ ~s{href="/admin/config/media-servers"}
    end
  end

  describe "Activity panel with usernameless users" do
    # OIDC-created users have a nil username (see User.role_changeset/2), so every
    # activity card must fall back rather than assume a binary is present.
    defp status_tab_assigns(overrides) do
      Map.merge(
        %{
          system_info: %{
            app_version: "1.2.3",
            dev_mode: false,
            elixir_version: "1.19.5",
            memory_used: "128.0 MB",
            uptime: "1h 2m"
          },
          database_info: %{
            adapter: :sqlite,
            path: "/config/mydia.db",
            size: "4.0 MB",
            exists: true,
            health: :healthy
          },
          library_paths_count: 0,
          download_clients_count: 0,
          indexers_count: 0,
          stuck_upgrades: 0,
          active_sessions: [],
          active_jobs: [],
          recent_activity: []
        },
        overrides
      )
    end

    test "renders an active streaming session for an OIDC user with no username" do
      oidc_user = %Mydia.Accounts.User{
        id: Ecto.UUID.generate(),
        username: nil,
        email: "oidc@example.com",
        role: "admin"
      }

      session = %Mydia.Streaming.ActiveSession{
        session_id: "sess-1",
        user: oidc_user,
        media_title: "Some Movie",
        media_type: :movie,
        episode_info: nil,
        mode: :direct,
        started_at: DateTime.utc_now(),
        ready: true
      }

      html =
        render_component(
          &MydiaWeb.AdminSystemLive.Components.status_tab/1,
          status_tab_assigns(%{active_sessions: [session]})
        )

      assert html =~ "Some Movie"

      # Avatar initials fall back to the email rather than crashing on nil.
      assert html =~ ~r{class="avatar placeholder".*?<span[^>]*>\s*oi\s*</span>}s
    end

    test "renders an active transcode job for an OIDC user with no username" do
      oidc_user = %Mydia.Accounts.User{
        id: Ecto.UUID.generate(),
        username: nil,
        email: "oidc@example.com",
        role: "admin"
      }

      job = %{
        id: Ecto.UUID.generate(),
        type: "stream",
        status: "transcoding",
        progress: 0.42,
        error: nil,
        resolution: "1080p",
        file_size: nil,
        started_at: DateTime.utc_now(),
        user_id: oidc_user.id,
        user: oidc_user,
        media_file: %{
          episode: nil,
          media_item: %{title: "Some Movie"},
          relative_path: "Movies/some-movie.mkv",
          path: nil
        }
      }

      html =
        render_component(
          &MydiaWeb.AdminSystemLive.Components.status_tab/1,
          status_tab_assigns(%{active_jobs: [job]})
        )

      assert html =~ "oidc@example.com"
    end
  end

  # Factory-inserted rows get `inserted_at` autogenerated to "now", which is
  # inside the one-hour grace window `Mydia.Health.upgrade_health/0` allows a
  # freshly imported upgrade. Back it up so the row reads as genuinely stuck.
  defp backdate!(%MediaFile{id: id}, hours: hours) do
    old_timestamp =
      DateTime.utc_now() |> DateTime.add(-hours, :hour) |> DateTime.truncate(:second)

    {1, _} =
      from(f in MediaFile, where: f.id == ^id)
      |> Repo.update_all(set: [inserted_at: old_timestamp])

    :ok
  end
end
