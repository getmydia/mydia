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

    test "opens only the hub holding the current page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, "details#admin-nav-administration[open]")
      assert has_element?(view, "details#admin-nav-configuration")
      refute has_element?(view, "details#admin-nav-configuration[open]")
      assert has_element?(view, "details#admin-nav-system")
      refute has_element?(view, "details#admin-nav-system[open]")
    end

    test "marks only the current page's link active", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(view, ~s|a#admin-nav-link-trash.active[href="/admin/trash"]|)
      refute has_element?(view, "a#admin-nav-link-duplicates.active")
    end

    test "lists the pages of closed hubs too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      assert has_element?(
               view,
               ~s|details#admin-nav-configuration a[href="/admin/quality"]|,
               "Quality"
             )

      assert has_element?(view, ~s|details#admin-nav-system a[href="/admin/status"]|, "Status")
    end

    test "shows the pending-requests count on the Administration hub and on Requests", %{
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

      assert has_element?(view, "#admin-nav-administration summary .badge", "1")
      assert has_element?(view, "#admin-nav-link-requests .badge", "1")
      refute has_element?(view, "#admin-nav-configuration summary .badge")
      refute has_element?(view, "#admin-nav-system summary .badge")
    end

    test "shows no count when nothing is pending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/trash")

      refute has_element?(view, "#admin-nav-administration summary .badge")
      refute has_element?(view, "#admin-nav-link-requests .badge")
    end
  end

  test "a non-admin sees no Admin section" do
    conn = log_in_user(build_conn(), user_fixture())

    {:ok, view, _html} = live(conn, ~p"/movies")

    refute has_element?(view, "li.menu-title", "Admin")
    refute has_element?(view, "details#admin-nav-configuration")
  end
end
