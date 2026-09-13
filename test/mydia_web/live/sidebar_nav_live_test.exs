defmodule MydiaWeb.SidebarNavLiveTest do
  @moduledoc """
  The sidebar's sections, who sees them, its labels and its badges, as a real
  page renders them. `MydiaWeb.AdminNavLiveTest` covers the Admin hub links.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Repo
  alias Mydia.Accounts
  alias Mydia.Changelog
  alias Mydia.Settings

  defp mount_as(role, path \\ "/calendar") do
    conn = log_in_user(build_conn(), user_fixture(%{role: role}))
    {:ok, view, _html} = live(conn, path)
    view
  end

  defp put_import_lists_enabled(value) do
    original = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, Keyword.put(original, :import_lists_enabled, value))
    on_exit(fn -> Application.put_env(:mydia, :features, original) end)
  end

  describe "sections by role" do
    setup do
      put_import_lists_enabled(true)
    end

    test "a guest sees Library and My Requests, and nothing to act on" do
      view = mount_as("guest")

      assert has_element?(view, "#nav-title-library")
      assert has_element?(view, ~s|a#nav-my-requests[href="/requests"]|, "My Requests")
      refute has_element?(view, "#nav-title-acquisition")
      refute has_element?(view, "#nav-title-admin")
      refute has_element?(view, ~s|aside nav a[href="/downloads"]|)
      refute has_element?(view, ~s|aside nav a[href="/import"]|)
      refute has_element?(view, ~s|aside nav a[href="/search"]|)
      refute has_element?(view, "li.menu-title", "Requests")
    end

    test "a readonly user sees Library only" do
      view = mount_as("readonly")

      assert has_element?(view, "#nav-title-library")
      refute has_element?(view, "#nav-my-requests")
      refute has_element?(view, "#nav-title-acquisition")
      refute has_element?(view, "#nav-title-admin")
    end

    test "a user sees Acquisition without Import Lists" do
      view = mount_as("user")

      assert has_element?(view, "#nav-title-acquisition", "Acquisition")

      for path <- ~w(/search /downloads /import /activity) do
        assert has_element?(view, ~s|aside nav a[href="#{path}"]|)
      end

      refute has_element?(view, "#nav-import-lists")
      refute has_element?(view, "#nav-my-requests")
      refute has_element?(view, "#nav-title-admin")
    end

    test "an admin sees every section, with Import Lists in Acquisition" do
      view = mount_as("admin")

      assert has_element?(view, "#nav-title-library")
      assert has_element?(view, "#nav-title-acquisition")
      assert has_element?(view, "#nav-title-admin", "Admin")
      assert has_element?(view, ~s|a#nav-import-lists[href="/admin/import-lists"]|)
      refute has_element?(view, "#nav-my-requests")
      refute has_element?(view, "li.menu-title", "Management")
    end

    test "the Library heading carries the add-section button" do
      view = mount_as("user")

      assert has_element?(
               view,
               ~s|#nav-title-library a#nav-add-section[href="/sections/new"][aria-label="Add section"]|
             )
    end

    test "Library lists Movies, TV Shows, Collections and Calendar" do
      view = mount_as("guest")

      for path <- ~w(/movies /tv /collections /calendar) do
        assert has_element?(view, ~s|aside nav a[href="#{path}"]|)
      end
    end
  end

  describe "labels" do
    test "the root page is Home in the sidebar and the tab title" do
      warm_trending_cache(:movie, [])
      warm_trending_cache(:tv_show, [])

      conn = log_in_user(build_conn(), user_fixture())
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s|a#nav-home.menu-active[href="/"]|, "Home")
      refute has_element?(view, ~s|aside nav a[href="/"]|, "Dashboard")
      assert page_title(view) =~ "Home"
    end

    test "the Downloads page is titled Downloads, not Activity" do
      conn = log_in_user(build_conn(), admin_user_fixture())
      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert page_title(view) =~ "Downloads"
      refute page_title(view) =~ "Activity"
      assert has_element?(view, "h1", "Downloads")
    end
  end

  describe "badges" do
    test "Downloads shows no badge with nothing downloading" do
      view = mount_as("admin")

      refute has_element?(view, "#nav-downloads-badge")
      refute has_element?(view, ~s|aside nav a[href="/downloads"] .badge|)
    end

    test "Movies and TV Shows show muted totals, not badges" do
      view = mount_as("user")

      assert has_element?(view, "#nav-movie-count", "0")
      assert has_element?(view, "#nav-tv-count", "0")
      refute has_element?(view, "#nav-movie-count.badge")
      refute has_element?(view, "#nav-tv-count.badge")
    end
  end

  describe "running jobs" do
    setup do
      %{}
      |> Oban.Job.new(worker: Mydia.Jobs.LibraryScanner, queue: :default)
      |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
      |> Repo.insert!()

      :ok
    end

    test "admins see the card, linked to Background Jobs" do
      view = mount_as("admin")

      assert has_element?(view, ~s|a#sidebar-running-jobs[href="/admin/jobs"]|)
    end

    test "non-admins do not see the card" do
      for role <- ~w(user readonly guest) do
        refute has_element?(mount_as(role), "#sidebar-running-jobs")
      end
    end
  end

  describe "account menu" do
    setup do
      admin = admin_user_fixture()
      %{conn: log_in_user(build_conn(), admin), admin: admin}
    end

    test "is the last block of the sidebar, below the nav", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      assert has_element?(view, "aside > #sidebar-account:last-child")
      refute has_element?(view, "#sidebar-account + nav")
      assert has_element?(view, "#sidebar-account .dropdown.dropdown-top #sidebar-user-menu")
      assert has_element?(view, "#sidebar-user-menu .avatar.avatar-placeholder")
    end

    test "holds the personal pages, theme, What's new, feedback and Log out", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      assert has_element?(view, ~s|#sidebar-account a#user-menu-profile[href="/profile"]|)

      assert has_element?(
               view,
               ~s|#sidebar-account a#user-menu-integrations[href="/integrations"]|
             )

      assert has_element?(view, ~s|#sidebar-account a#user-menu-devices[href="/devices"]|)
      assert has_element?(view, "#sidebar-account #theme-toggle-account")
      assert has_element?(view, ~s|#sidebar-account a#user-menu-changelog[href="/changelog"]|)

      assert has_element?(
               view,
               ~s|#sidebar-account button#user-menu-feedback[phx-click="open_feedback_modal"]|,
               "Send feedback"
             )

      assert has_element?(view, ~s|#sidebar-account a[href="/auth/logout"]|, "Log out")
    end

    test "replaces the feedback card and the sidebar theme row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/calendar")

      refute has_element?(view, "#sidebar-send-feedback")
      refute has_element?(view, "#theme-toggle-sidebar")
      refute has_element?(view, ~s|aside nav a[href="/integrations"]|)
      refute has_element?(view, ~s|aside nav a[href="/devices"]|)
    end

    test "has no feedback item when feedback is disabled", %{conn: conn} do
      {:ok, _setting} =
        Settings.create_config_setting(%{
          key: "feedback.enabled",
          value: "false",
          category: :feedback
        })

      {:ok, view, _html} = live(conn, ~p"/calendar")

      refute has_element?(view, "#user-menu-feedback")
    end

    test "marks What's new only while release notes are unread", %{conn: conn, admin: admin} do
      {:ok, _} = Accounts.mark_changelog_seen(admin, "0.2.0")
      {:ok, view, _html} = live(conn, ~p"/calendar")
      assert has_element?(view, "#user-menu-changelog .badge", "New")

      {:ok, _} = Accounts.mark_changelog_seen(admin, Changelog.latest())
      {:ok, view, _html} = live(conn, ~p"/calendar")
      refute has_element?(view, "#user-menu-changelog .badge")
    end

    test "names a user without a username by their display name" do
      user = nameless_user_fixture(%{display_name: "Wren Halloway"})
      conn = log_in_user(build_conn(), user)

      {:ok, view, _html} = live(conn, ~p"/calendar")

      assert has_element?(view, "#sidebar-user-menu", "Wren Halloway")
      assert has_element?(view, "#sidebar-user-menu span", "WR")
    end
  end
end
