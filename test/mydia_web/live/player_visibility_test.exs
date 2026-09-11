defmodule MydiaWeb.PlayerVisibilityTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    # DashboardLive.Index loads both trending rails on connected mount.
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  defp hide_player(user) do
    {:ok, _} =
      user
      |> Accounts.get_user_preference!()
      |> Accounts.update_preference(%{"hide_player" => true})

    :ok
  end

  test "the sidebar pill and dock tab render by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#sidebar-player-link")
    assert has_element?(view, "#dock-player-link")
  end

  test "hide_player removes the sidebar pill and dock tab", %{conn: conn, user: user} do
    :ok = hide_player(user)

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#sidebar-player-link")
    refute has_element?(view, "#dock-player-link")
  end

  test "hide_player leaves the movie Play button alone", %{conn: conn, user: user} do
    :ok = hide_player(user)

    _library = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Quiet Harbour", year: 2024})
    _file = media_file_fixture(%{media_item_id: item.id})

    {:ok, view, _html} = live(conn, ~p"/movies/#{item.id}")

    assert has_element?(view, ~s{a[href^="/player/#/player/movie/"]})
  end

  test "the banner renders by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#player-cta-banner")
  end

  test "dismissing removes the banner and persists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#player-cta-banner")

    view |> element("#dismiss-player-banner") |> render_click()

    refute has_element?(view, "#player-cta-banner")

    {:ok, remounted, _html} = live(conn, ~p"/")
    refute has_element?(remounted, "#player-cta-banner")
  end

  test "dismissing leaves the sidebar pill and dock tab in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#dismiss-player-banner") |> render_click()

    assert has_element?(view, "#sidebar-player-link")
    assert has_element?(view, "#dock-player-link")
  end

  test "hide_player removes the banner even when it was never dismissed", %{
    conn: conn,
    user: user
  } do
    :ok = hide_player(user)
    refute UserPreference.player_banner_dismissed?(Accounts.get_user_preference!(user))

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#player-cta-banner")
  end

  test "the Devices web tile renders by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")

    assert has_element?(view, "#download-web")
  end

  test "hide_player removes the Devices web tile but keeps the native downloads", %{
    conn: conn,
    user: user
  } do
    :ok = hide_player(user)

    {:ok, view, _html} = live(conn, ~p"/devices")

    refute has_element?(view, "#download-web")
    assert has_element?(view, "#download-card")
  end

  test "the toggle turns the setting on and hides the sidebar pill in the same render", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/profile")
    assert has_element?(view, "#sidebar-player-link")

    view |> element("#hide-player-toggle") |> render_click()

    refute has_element?(view, "#sidebar-player-link")
    assert UserPreference.hide_player?(Accounts.get_user_preference!(user))
  end

  test "the toggle turns the setting back off", %{conn: conn, user: user} do
    :ok = hide_player(user)

    {:ok, view, _html} = live(conn, ~p"/profile")
    refute has_element?(view, "#sidebar-player-link")

    view |> element("#hide-player-toggle") |> render_click()

    assert has_element?(view, "#sidebar-player-link")
    refute UserPreference.hide_player?(Accounts.get_user_preference!(user))
  end

  test "turning the setting off does not bring back a dismissed banner", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Accounts.dismiss_player_banner(user)
    :ok = hide_player(user)

    {:ok, profile, _html} = live(conn, ~p"/profile")
    profile |> element("#hide-player-toggle") |> render_click()

    {:ok, dashboard, _html} = live(conn, ~p"/")

    refute has_element?(dashboard, "#player-cta-banner")
    assert has_element?(dashboard, "#sidebar-player-link")
  end

  describe "with the player off" do
    setup do
      disable_player()
    end

    test "every entry point is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      refute has_element?(view, "#sidebar-player-link")
      refute has_element?(view, "#dock-player-link")
      refute has_element?(view, "#player-cta-banner")
      refute has_element?(view, ~s{a[href="/devices"]})
    end

    test "the profile drops the hide-player toggle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profile")

      refute has_element?(view, "#hide-player-toggle")
    end

    test "the admin tabs drop Dashboard and Remote Access", %{conn: conn} do
      start_supervised!(Mydia.Indexers.Health)
      {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

      refute has_element?(view, ~s{a[href="/admin/dashboard"]})
      refute has_element?(view, ~s{a[href="/admin/config/remote-access"]})
    end

    test "admin settings drop the Streaming category", %{conn: conn} do
      start_supervised!(Mydia.Indexers.Health)
      {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

      refute has_element?(view, "#hwaccel-status")
    end
  end

  describe "with the player on" do
    test "the Devices link and the admin tabs are there", %{conn: conn} do
      start_supervised!(Mydia.Indexers.Health)

      {:ok, home, _html} = live(conn, ~p"/")
      assert has_element?(home, ~s{a[href="/devices"]})

      {:ok, settings, _html} = live(conn, ~p"/admin/config/settings")
      assert has_element?(settings, ~s{a[href="/admin/dashboard"]})
      assert has_element?(settings, "#hwaccel-status")
    end
  end
end
