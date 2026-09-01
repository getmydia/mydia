defmodule MydiaWeb.PlayerVisibilityTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Accounts

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
end
