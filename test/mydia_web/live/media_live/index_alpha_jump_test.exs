defmodule MydiaWeb.MediaLive.IndexAlphaJumpTest do
  # async: false for the same Postgres sandbox reason as library_filter_test.exs.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  # 60 "Alder" titles push M past the first batch of 50.
  defp library do
    alders = for i <- 1..60, do: movie("Alder #{pad(i)}")
    marrows = for i <- 1..5, do: movie("Marrow #{pad(i)}")
    zephyr = movie("Zephyr Hollow")
    %{alders: alders, marrows: marrows, zephyr: zephyr}
  end

  defp movie(title), do: media_item_fixture(%{type: "movie", title: title})
  defp pad(i), do: String.pad_leading(to_string(i), 3, "0")

  defp card_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#media-items > [id^='media_items-']")
    |> Enum.map(&(LazyHTML.attribute(&1, "id") |> List.first()))
  end

  defp card(item), do: "media_items-#{item.id}"

  @tag :alpha_bar
  @tag skip: "bar lands in Task 4"
  test "the bar shows on title sorts and marks letters without titles", %{conn: conn} do
    library()
    {:ok, view, _html} = live(conn, ~p"/movies")

    assert has_element?(view, "#alpha-jump-bar")
    assert has_element?(view, "a#alpha-jump-m")
    assert has_element?(view, "span#alpha-jump-b[aria-disabled=true]")
    assert has_element?(view, "span#alpha-jump-hash[aria-disabled=true]")
  end

  @tag :alpha_bar
  @tag skip: "bar lands in Task 4"
  test "the bar is hidden under other sorts and while searching", %{conn: conn} do
    library()
    {:ok, view, _html} = live(conn, ~p"/movies?sort=year_desc")
    refute has_element?(view, "#alpha-jump-bar")

    {:ok, view, _html} = live(conn, ~p"/movies?q=alder")
    refute has_element?(view, "#alpha-jump-bar")
  end

  test "a letter starts the list at its first title and keeps it in the URL", %{conn: conn} do
    %{marrows: [first_m | _]} = library()
    {:ok, view, _html} = live(conn, ~p"/movies")

    render_patch(view, "/movies?letter=m")
    assert_push_event(view, "alpha_jump:scroll_top", %{})

    assert hd(card_ids(view)) == card(first_m)
    assert has_element?(view, "#media-items-top-sentinel")
  end

  test "load_previous prepends the titles above, in order", %{conn: conn} do
    %{alders: alders, marrows: [first_m | _]} = library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")

    render_hook(view, "load_previous", %{})

    ids = card_ids(view)
    expected_before = alders |> Enum.drop(60 - 48) |> Enum.map(&card/1)
    assert Enum.take(ids, 48) == expected_before
    assert Enum.at(ids, 48) == card(first_m)

    render_hook(view, "load_previous", %{})
    assert hd(card_ids(view)) == card(hd(alders))
    refute has_element?(view, "#media-items-top-sentinel")
  end

  # 70 "Marrow" titles, so the first batch from M stops short of the end.
  defp long_library do
    alders = for i <- 1..60, do: movie("Alder #{pad(i)}")
    marrows = for i <- 1..70, do: movie("Marrow #{pad(i)}")
    zephyr = movie("Zephyr Hollow")
    %{alders: alders, marrows: marrows, zephyr: zephyr}
  end

  test "load_more after a jump continues past the letter", %{conn: conn} do
    %{marrows: marrows, zephyr: zephyr} = long_library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")

    assert card_ids(view) == marrows |> Enum.take(50) |> Enum.map(&card/1)

    render_hook(view, "load_more", %{})

    assert card_ids(view) == Enum.map(marrows ++ [zephyr], &card/1)
    assert_patch(view, "/movies?letter=m&shown=71")
  end

  test "shown counts from the letter, not the rows loaded above it", %{conn: conn} do
    %{alders: alders, marrows: marrows, zephyr: zephyr} = long_library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")

    render_hook(view, "load_previous", %{})
    render_hook(view, "load_more", %{})

    expected = alders |> Enum.drop(60 - 48) |> Kernel.++(marrows) |> Kernel.++([zephyr])
    assert card_ids(view) == Enum.map(expected, &card/1)
    assert_patch(view, "/movies?letter=m&shown=71")

    # A reload starts back at the letter and keeps the rows below it.
    render_click(view, "toggle_view", %{"mode" => "list"})
    assert card_ids(view) == Enum.map(marrows ++ [zephyr], &card/1)
  end

  test "only an in-page jump scrolls to the top", %{conn: conn} do
    library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")
    refute_push_event(view, "alpha_jump:scroll_top", %{})

    render_patch(view, "/movies?letter=z")
    assert_push_event(view, "alpha_jump:scroll_top", %{})
  end

  test "a letter with no titles starts at the next letter", %{conn: conn} do
    %{zephyr: zephyr} = library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=q")

    assert hd(card_ids(view)) == card(zephyr)
  end

  test "Z-A starts at the letter in descending order", %{conn: conn} do
    %{marrows: marrows} = library()
    {:ok, view, _html} = live(conn, ~p"/movies?sort=title_desc&letter=m")

    assert hd(card_ids(view)) == card(List.last(marrows))
  end

  test "a reload keeps the window at the letter", %{conn: conn} do
    %{marrows: [first_m | _]} = library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")

    render_click(view, "toggle_view", %{"mode" => "list"})

    assert hd(card_ids(view)) == card(first_m)
  end

  test "changing the sort drops the letter", %{conn: conn} do
    library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=m")

    view
    |> element("#library-filter-form")
    |> render_change(%{
      "progress" => "",
      "monitored" => "all",
      "quality" => "",
      "sort_by" => "year_desc"
    })

    assert_patch(view, "/movies?sort=year_desc")
  end

  test "cards carry their initial", %{conn: conn} do
    %{zephyr: zephyr} = library()
    {:ok, view, _html} = live(conn, ~p"/movies?letter=z")

    assert has_element?(view, "##{card(zephyr)}[data-initial=z]")
  end
end
