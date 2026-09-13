defmodule MydiaWeb.AdminNavLiveTest do
  @moduledoc """
  The sidebar's Admin section and the admin page header, as real admin pages
  render them. `MydiaWeb.AdminNavTest` covers the registry behind both.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.MediaRequests

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  describe "sidebar" do
    test "names the section Admin", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "li.menu-title", "Admin")
      refute has_element?(view, "li.menu-title", "Administration")
    end

    test "links each hub to its first page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(
               view,
               ~s|a#admin-nav-configuration[href="/admin/quality"]|,
               "Configuration"
             )

      assert has_element?(
               view,
               ~s|a#admin-nav-administration[href="/admin/requests"]|,
               "Administration"
             )

      assert has_element?(view, ~s|a#admin-nav-system[href="/admin/status"]|, "System")
      refute has_element?(view, "details[id^=admin-nav-]")
    end

    test "marks only the hub holding the current page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "a#admin-nav-administration.menu-active")
      refute has_element?(view, "a#admin-nav-configuration.menu-active")
      refute has_element?(view, "a#admin-nav-system.menu-active")
    end

    test "shows the pending-requests count on the Administration hub", %{
      conn: conn
    } do
      guest = user_fixture(%{role: "guest"})

      {:ok, _request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "The Paper Orchard",
          year: 2024,
          tmdb_id: System.unique_integer([:positive]),
          requester_id: guest.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "a#admin-nav-administration .badge", "1")
      refute has_element?(view, "a#admin-nav-configuration .badge")
      refute has_element?(view, "a#admin-nav-system .badge")
    end

    test "shows no count when nothing is pending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      refute has_element?(view, "a#admin-nav-administration .badge")
    end

    test "Activity is in Acquisition for admins", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "#nav-title-acquisition")
      assert has_element?(view, ~s|nav a[href="/activity"]|, "Activity")
      refute has_element?(view, "#admin-tab-activity")
    end
  end

  describe "page header" do
    test "names the hub, the page and its description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "#admin-page-hub", "Administration")
      assert has_element?(view, "h1#admin-page-title", "Trash")
      assert has_element?(view, "#admin-page-description", "Deleted files waiting to be purged")
      assert has_element?(view, "#admin-page-actions #trash-scan")
      assert has_element?(view, "#admin-page-count", "0")
    end

    test "a page's card header merges into the page header", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/clients")

      assert has_element?(view, "h1#admin-page-title", "Clients")
      assert has_element?(view, "#admin-page-count", "0")
      assert has_element?(view, "#admin-page-actions button[phx-click=new_download_client]")
      refute has_element?(view, "main h2", "Download Clients")
    end

    test "pages without a list show no count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      refute has_element?(view, "#admin-page-count")
    end

    test "tabs list the current hub's pages with the current page active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      for key <- ~w(requests jobs release_blacklist duplicates trash) do
        assert has_element?(view, "#admin-page-tabs a#admin-tab-#{key}[role=tab]")
      end

      assert has_element?(
               view,
               ~s|#admin-page-tabs a#admin-tab-trash.tab-active[href="/admin/trash"]|
             )

      refute has_element?(view, "#admin-page-tabs a#admin-tab-duplicates.tab-active")
      refute has_element?(view, "#admin-page-tabs a#admin-tab-quality")
      refute has_element?(view, "#admin-page-tabs a#admin-tab-status")
    end

    test "Users puts Create Local User in the header and keeps the OIDC banner in the body", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert has_element?(view, "#admin-page-hub", "System")
      assert has_element?(view, "h1#admin-page-title", "Users")
      assert has_element?(view, "#admin-page-actions button[phx-click=open_create_modal]")
      assert has_element?(view, ".alert", "OIDC Auto-Registration")
    end

    test "Requests uses the registry label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/requests")

      assert has_element?(view, "h1#admin-page-title", "Requests")
      refute has_element?(view, "h1", "Manage Media Requests")
    end

    test "Import Lists is an Acquisition page with its own header", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/import-lists")

      assert has_element?(view, "h1", "Import Lists")
      assert has_element?(view, "button[phx-click=sync_all]")
      assert has_element?(view, "button[phx-click=new_list]")
      refute has_element?(view, "#admin-page-tabs")
      refute has_element?(view, "#admin-page-hub")
      assert has_element?(view, ~s|a#nav-import-lists.menu-active[href="/admin/import-lists"]|)
      refute has_element?(view, "#admin-tab-import_lists")
    end

    test "Release Blacklist keeps its TTL note in the body", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/release-blacklist")

      assert has_element?(
               view,
               "#admin-page-description",
               "Releases blocked from future searches"
             )

      assert has_element?(view, "#blacklist-ttl-note", "Default TTL is 30 days")
    end

    test "Background Jobs puts Refresh in the header", %{conn: conn} do
      # JobsLive reads Oban.config/0, and Oban is not started in test.
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      assert has_element?(view, "#admin-page-hub", "Administration")
      assert has_element?(view, "h1#admin-page-title", "Background Jobs")
      assert has_element?(view, "#admin-page-actions button[phx-click=refresh]")
    end

    test "Requests filters by status with a segmented control, not tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/requests")

      assert has_element?(
               view,
               ~s|#requests-status-filter button[phx-value-status="pending"][aria-pressed="true"]|
             )

      assert has_element?(view, "[role=tablist]#admin-page-tabs")

      assert view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("main [role=tablist]")
             |> Enum.count() == 1
    end

    test "Background Jobs uses theme colours and the shared section style", %{conn: conn} do
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

      {:ok, view, _html} = live(conn, ~p"/admin/jobs")

      assert has_element?(view, "h2.text-lg", "Scheduled Jobs")
      assert has_element?(view, "h2.text-lg", "Job History")
      refute render(view) =~ "text-gray-"
    end
  end

  test "a non-admin sees no Admin section" do
    conn = log_in_user(build_conn(), user_fixture())

    {:ok, view, _html} = live(conn, ~p"/movies")

    refute has_element?(view, "li.menu-title", "Admin")
    refute has_element?(view, "a#admin-nav-configuration")
    refute has_element?(view, "a#nav-import-lists")
    assert has_element?(view, ~s|nav a[href="/activity"]|)
  end
end
