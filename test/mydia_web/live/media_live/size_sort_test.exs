defmodule MydiaWeb.MediaLive.SizeSortTest do
  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise. Same reason as added_sort_test.exs.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "the sort menu offers both size orders", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies")

    assert has_element?(
             view,
             "#library-filter-form select[name=sort_by] option[value=size_desc]"
           )

    assert has_element?(
             view,
             "#library-filter-form select[name=sort_by] option[value=size_asc]"
           )
  end

  test "largest first orders by bytes on disk", %{conn: conn} do
    # Titles are chosen so title_asc order (Alderway before Zircon) is the
    # OPPOSITE of the required size_desc order (Zircon/big before
    # Alderway/small). The catch-all `sort(rows, _sort_by)` clause falls back
    # to title order, so if "size_desc" were not actually wired to
    # sort_by_size/2 this assertion would fail instead of passing by
    # alphabetical coincidence.
    small = media_item_fixture(%{type: "movie", title: "Alderway Fog"})
    media_file_fixture(%{media_item_id: small.id, size: 700_000_000})

    big = media_item_fixture(%{type: "movie", title: "Zircon Valley"})
    media_file_fixture(%{media_item_id: big.id, size: 40_000_000_000})

    {:ok, view, _html} = live(conn, ~p"/movies")

    html =
      view
      |> element("#library-filter-form")
      |> render_change(%{"sort_by" => "size_desc"})

    # Stream children are keyed `media_items-<item id>` by stream/3 and exist
    # in both view modes, so this cannot be satisfied by a title appearing
    # somewhere else on the page.
    {big_position, _} = :binary.match(html, "media_items-#{big.id}")
    {small_position, _} = :binary.match(html, "media_items-#{small.id}")

    assert big_position < small_position
  end

  test "smallest first leads with the smallest real file, not an empty item", %{conn: conn} do
    # Same title choice as above (Alderway before Zircon alphabetically), plus
    # a third title ("Mossbrook Hollow") that falls alphabetically between
    # them. Under a title_asc fallback the order would be small, empty, big
    # -- which satisfies small_position < big_position by coincidence but
    # fails big_position < empty_position, so a regression to the catch-all
    # still fails this test.
    small = media_item_fixture(%{type: "movie", title: "Alderway Fog"})
    media_file_fixture(%{media_item_id: small.id, size: 700_000_000})

    big = media_item_fixture(%{type: "movie", title: "Zircon Valley"})
    media_file_fixture(%{media_item_id: big.id, size: 40_000_000_000})

    empty = media_item_fixture(%{type: "movie", title: "Mossbrook Hollow"})

    {:ok, view, _html} = live(conn, ~p"/movies")

    html =
      view
      |> element("#library-filter-form")
      |> render_change(%{"sort_by" => "size_asc"})

    {small_position, _} = :binary.match(html, "media_items-#{small.id}")
    {big_position, _} = :binary.match(html, "media_items-#{big.id}")
    {empty_position, _} = :binary.match(html, "media_items-#{empty.id}")

    assert small_position < big_position
    assert big_position < empty_position
  end
end
