defmodule MydiaWeb.MediaLive.FixMatchTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures

  test "opens the fix match search for an operator who may delete media", %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    view |> element("#fix-match-button") |> render_click()

    assert has_element?(view, "#fix-match-modal")
    assert has_element?(view, "#fix-match-search-form input[value='Wrong Pick']")
  end

  test "a guest cannot open it", %{conn: conn} do
    {conn, _guest} = register_and_log_in_user(conn, %{role: "guest"})
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    render_click(view, "open_fix_match", %{})

    refute has_element?(view, "#fix-match-modal")
  end
end
