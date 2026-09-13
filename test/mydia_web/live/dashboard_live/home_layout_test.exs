defmodule MydiaWeb.DashboardLive.HomeLayoutTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Accounts

  setup do
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  test "disconnected and connected mount assign home_widgets and modal states", %{conn: conn} do
    user = user_fixture(%{role: "admin"})
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#edit-home-btn")
    assert has_element?(view, "#system-health-widget")
    refute has_element?(view, "#edit-home-modal[open]")
  end

  test "open_edit_home and close_edit_home toggle modal visibility", %{conn: conn} do
    user = user_fixture(%{role: "user"})
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#edit-home-btn") |> render_click()
    assert has_element?(view, "#edit-home-modal[open]")

    view |> element("#edit-home-modal button", "Done") |> render_click()
    refute has_element?(view, "#edit-home-modal[open]")
  end

  test "empty visible widgets renders #home-empty state", %{conn: conn} do
    user = user_fixture(%{role: "user"})
    {:ok, _} = Accounts.put_home_widgets(user, [])
    conn = log_in_user(conn, user)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-empty")
    assert has_element?(view, "#home-empty button", "Edit Home")
  end

  test "getting started links to Discover when library is empty", %{conn: conn} do
    user = user_fixture(%{role: "user"})
    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "Start by adding movies or TV shows from"
    assert html =~ ~s(href="/discover")
  end

  describe "layout event handlers" do
    test "open_edit_home and close_edit_home toggle editing_home assign", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      assert :sys.get_state(view.pid).socket.assigns.editing_home == false
      render_hook(view, "open_edit_home", %{})
      assert :sys.get_state(view.pid).socket.assigns.editing_home == true
      render_hook(view, "close_edit_home", %{})
      assert :sys.get_state(view.pid).socket.assigns.editing_home == false
    end

    test "toggle_home_widget toggles widget and persists to user preferences", %{conn: conn} do
      user = user_fixture(%{role: "admin"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      assert :episodes in :sys.get_state(view.pid).socket.assigns.home_widgets
      render_hook(view, "toggle_home_widget", %{"key" => "episodes"})
      refute :episodes in :sys.get_state(view.pid).socket.assigns.home_widgets
      refute :episodes in Accounts.home_widgets(user)

      render_hook(view, "toggle_home_widget", %{"key" => "episodes"})
      assert :episodes in :sys.get_state(view.pid).socket.assigns.home_widgets
      assert :episodes in Accounts.home_widgets(user)
    end

    test "move_home_widget reorders widgets and persists to user preferences", %{conn: conn} do
      user = user_fixture(%{role: "admin"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      initial_widgets = Accounts.home_widgets(user)
      first = Enum.at(initial_widgets, 0)
      second = Enum.at(initial_widgets, 1)

      render_hook(view, "move_home_widget", %{"key" => to_string(first), "direction" => "down"})
      updated_widgets = Accounts.home_widgets(user)
      assert Enum.at(updated_widgets, 0) == second
      assert Enum.at(updated_widgets, 1) == first
    end

    test "reset_home_widgets resets preferences to defaults", %{conn: conn} do
      user = user_fixture(%{role: "admin"})
      {:ok, _} = Accounts.put_home_widgets(user, [:library_stats])
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      assert :sys.get_state(view.pid).socket.assigns.home_widgets == [:library_stats]
      render_hook(view, "reset_home_widgets", %{})
      assert length(:sys.get_state(view.pid).socket.assigns.home_widgets) > 1
      assert length(Accounts.home_widgets(user)) > 1
    end
  end

  describe "data loading and role gating" do
    test "system health is only loaded for admin users", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, user_view, _html} = live(log_in_user(conn, user), ~p"/")
      user_assigns = :sys.get_state(user_view.pid).socket.assigns
      assert user_assigns.clients_rollup.state == :none

      admin = user_fixture(%{role: "admin"})
      {:ok, admin_view, _html} = live(log_in_user(conn, admin), ~p"/")
      admin_assigns = :sys.get_state(admin_view.pid).socket.assigns
      assert admin_assigns.clients_rollup != nil
      assert admin_assigns.trash_summary != nil
    end

    test "trending prerequisites are not loaded when trending widgets are hidden", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, _} = Accounts.put_home_widgets(user, [:library_stats, :quick_actions])
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.trending_prerequisites_loaded == false
      assert assigns.library_status_map == %{}
      assert assigns.request_status_map == %{}
      assert assigns.quality_profiles == []
    end
  end

  describe "async task handlers and health refresh" do
    test "handle_async :duplicate_count updates duplicates state and count", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/")

      # Give the LiveView async task time to complete
      Process.sleep(100)
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.duplicates_state in [:none, :review]
      assert is_integer(assigns.duplicates_count)
    end

    test "handle_info :refresh_health refreshes health assigns for admin", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/")

      send(view.pid, :refresh_health)
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.clients_rollup != nil
      assert assigns.trash_summary != nil
    end

    test "handle_info :refresh_health is ignored when user is not admin", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      send(view.pid, :refresh_health)
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.clients_rollup.state == :none
    end
  end

  describe "integration: layout customization and rendering" do
    test "default widgets and order for admin and guest", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      {:ok, admin_view, _} = live(log_in_user(conn, admin), ~p"/")

      assert has_element?(admin_view, "#library-stats-widget")
      assert has_element?(admin_view, "#system-health-widget")
      assert has_element?(admin_view, "#quick-actions-widget")

      admin_html = render(admin_view)
      stats_pos = :binary.match(admin_html, "id=\"library-stats-widget\"") |> elem(0)
      health_pos = :binary.match(admin_html, "id=\"system-health-widget\"") |> elem(0)
      qa_pos = :binary.match(admin_html, "id=\"quick-actions-widget\"") |> elem(0)

      assert stats_pos < health_pos
      assert health_pos < qa_pos

      guest = user_fixture(%{role: "guest"})
      {:ok, guest_view, _} = live(log_in_user(conn, guest), ~p"/")

      assert has_element?(guest_view, "#library-stats-widget")
      refute has_element?(guest_view, "#system-health-widget")
      assert has_element?(guest_view, "#qa-request-movie")
    end

    test "stored custom layout renders in stored order", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, _} = Accounts.put_home_widgets(user, [:quick_actions, :library_stats])

      {:ok, view, _} = live(log_in_user(conn, user), ~p"/")

      assert has_element?(view, "#quick-actions-widget")
      assert has_element?(view, "#library-stats-widget")
      refute has_element?(view, "#trending-movies-widget")

      html = render(view)
      qa_pos = :binary.match(html, "id=\"quick-actions-widget\"") |> elem(0)
      stats_pos = :binary.match(html, "id=\"library-stats-widget\"") |> elem(0)
      assert qa_pos < stats_pos
    end

    test "toggle, move and reset through the modal persist and re-render", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, view, _} = live(log_in_user(conn, user), ~p"/")

      # Toggle off quick_actions
      view
      |> element("#edit-home-widget-quick_actions input[type=checkbox]")
      |> render_click()

      refute has_element?(view, "#quick-actions-widget")
      assert :quick_actions not in Accounts.home_widgets(user)

      # Move library_stats down
      view
      |> element("#edit-home-widget-library_stats button[aria-label='Move Library stats down']")
      |> render_click()

      assert Accounts.home_widgets(user) |> Enum.at(0) != :library_stats

      # Reset
      view
      |> element("#reset-home-widgets")
      |> render_click()

      assert :quick_actions in Accounts.home_widgets(user)
      assert has_element?(view, "#quick-actions-widget")
    end

    test "hiding both trending widgets means no load_trending messages are sent", %{conn: conn} do
      user = user_fixture(%{role: "user"})
      {:ok, _} = Accounts.put_home_widgets(user, [:library_stats])

      {:ok, view, _html} = live(log_in_user(conn, user), ~p"/")

      # No trending loading triggered
      refute_received :load_trending_movies
      refute_received :load_trending_tv

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.trending_prerequisites_loaded == false
    end
  end
end
