defmodule MydiaWeb.DiscoverLive.HideOwnedTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list on
    # connected mount (#530).
    warm_genre_cache(:movie, [])
    warm_trending_cache(:movie, [])

    user = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "the toggle renders and starts off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-hide-owned")
    refute has_element?(view, "#discover-hide-owned[checked]")
  end

  test "toggling persists to the user preference", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    view |> element("#discover-hide-owned") |> render_click()

    pref = Accounts.get_user_preference!(user)
    assert UserPreference.discover_hide_owned(pref) == true
  end

  test "the preference is honoured on the next mount", %{conn: conn, user: user} do
    pref = Accounts.get_user_preference!(user)

    {:ok, _} =
      Accounts.update_preference(pref, %{"preferences" => %{"discover_hide_owned" => true}})

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-hide-owned[checked]")
  end
end
