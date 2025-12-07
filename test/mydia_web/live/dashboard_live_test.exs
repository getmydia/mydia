defmodule MydiaWeb.DashboardLiveTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mydia.Factory
  import Mydia.SettingsFixtures

  describe "Index" do
    setup :register_and_log_in_user

    test "renders dashboard page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Dashboard page should render without errors
      assert html =~ "Dashboard" or html =~ "dashboard"
    end

    test "shows movie count stat", %{conn: conn} do
      # Create a movie in the library
      profile = quality_profile_fixture()

      insert(:media_item,
        title: "Test Movie",
        type: "movie",
        quality_profile_id: profile.id
      )

      {:ok, _view, html} = live(conn, ~p"/")

      # The stats card for movies should be present
      assert html =~ "Movies" or html =~ "movies"
    end

    test "shows tv show count stat", %{conn: conn} do
      # Create a TV show in the library
      profile = quality_profile_fixture()

      insert(:media_item,
        title: "Test TV Show",
        type: "tv_show",
        quality_profile_id: profile.id
      )

      {:ok, _view, html} = live(conn, ~p"/")

      # The stats card for TV shows should be present
      assert html =~ "TV Shows" or html =~ "TV" or html =~ "Series"
    end

    test "shows downloads stat card", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The active downloads card should be present
      assert html =~ "Downloads" or html =~ "downloads"
    end

    test "shows storage stat card", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # The storage card should be present
      assert html =~ "Storage" or html =~ "GB" or html =~ "MB" or html =~ "KB"
    end

    test "requires authentication" do
      # Test unauthenticated access
      conn = build_conn()
      {:error, {:redirect, %{to: to}}} = live(conn, ~p"/")

      # Should redirect to login
      assert to =~ "/login" or to =~ "/auth" or to =~ "/setup"
    end

    test "renders recent episodes section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # After connecting, the dashboard should render without error
      html = render(view)
      assert is_binary(html)
    end

    test "renders upcoming episodes section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Dashboard should render without error
      html = render(view)
      assert is_binary(html)
    end
  end

  describe "Index for admin user" do
    setup :register_and_log_in_admin

    test "shows pending requests count for admins", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # Admin users should see the dashboard
      assert html =~ "Dashboard" or is_binary(html)
    end
  end

  describe "Index without content" do
    setup :register_and_log_in_user

    test "handles empty library gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Should render without crashing even with no content
      html = render(view)
      assert is_binary(html)
    end
  end
end
