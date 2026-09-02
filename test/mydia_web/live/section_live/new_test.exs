defmodule MydiaWeb.SectionLive.NewTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Collections

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})
    %{conn: log_in_user(conn, user), user: user}
  end

  test "lists every preset", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sections/new")

    for preset <- Mydia.Collections.SectionPresets.all() do
      assert has_element?(view, "#preset-#{preset.key}")
    end
  end

  test "offers a custom option that goes to the collections page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sections/new")

    assert has_element?(view, "#preset-custom")
  end

  test "creating from a preset pins it and navigates to the section", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/sections/new")

    {:error, {:live_redirect, %{to: path}}} =
      view |> element("#preset-anime") |> render_click()

    assert [section] = Collections.list_pinned_sections(user)
    assert section.name == "Anime"
    assert section.exclusive
    assert section.sidebar_icon == "hero-bolt"
    assert path == "/sections/#{section.id}"
  end

  test "creating the same preset twice navigates to the existing section", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, ~p"/sections/new")
    view |> element("#preset-anime") |> render_click()

    {:ok, view2, _html} = live(conn, ~p"/sections/new")
    view2 |> element("#preset-anime") |> render_click()

    assert length(Collections.list_pinned_sections(user)) == 1
  end
end
