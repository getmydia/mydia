defmodule MydiaWeb.MediaLive.UrlStateTest do
  # async: false for the same Postgres sandbox reason as library_filter_test.exs.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp card_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#media-items [id^='media_items-']")
    |> Enum.count()
  end

  defp movies(n) do
    for i <- 1..n do
      media_item_fixture(%{
        type: "movie",
        title: "Fernlight #{String.pad_leading(to_string(i), 3, "0")}"
      })
    end
  end

  test "changing a filter or the sort patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies")

    view
    |> element("#library-filter-form")
    |> render_change(%{
      "progress" => "missing",
      "monitored" => "all",
      "quality" => "",
      "sort_by" => "year_desc"
    })

    assert_patch(view, "/movies?progress=missing&sort=year_desc")
  end

  test "searching patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies")

    view |> element("#library-search-form") |> render_change(%{"search" => "fern"})

    assert_patch(view, "/movies?q=fern")
  end

  test "mounting with params applies them", %{conn: conn} do
    missing = media_item_fixture(%{type: "movie", title: "Gullwing Pass"})
    have = media_item_fixture(%{type: "movie", title: "Orchid Causeway"})
    media_file_fixture(%{media_item_id: have.id})

    {:ok, view, _html} = live(conn, ~p"/movies?progress=missing&sort=title_desc")

    assert has_element?(view, "#media_items-#{missing.id}")
    refute has_element?(view, "#media_items-#{have.id}")
    assert has_element?(view, "select[name=progress] option[value=missing][selected]")
    assert has_element?(view, "select[name=sort_by] option[value=title_desc][selected]")
  end

  test "invalid params fall back to defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies?progress=bogus&sort=nope&shown=abc")

    assert has_element?(view, "select[name=progress] option[value=''][selected]")
    assert has_element?(view, "select[name=sort_by] option[value=title_asc][selected]")
  end

  test "shown renders that many rows on mount", %{conn: conn} do
    movies(70)

    {:ok, view, _html} = live(conn, ~p"/movies?shown=60")

    assert card_count(view) == 60
  end

  test "load_more appends a batch and records it in the URL", %{conn: conn} do
    movies(70)

    {:ok, view, _html} = live(conn, ~p"/movies")
    assert card_count(view) == 50

    render_hook(view, "load_more", %{})

    assert card_count(view) == 70
    assert_patch(view, "/movies?shown=70")
  end

  test "load_more skips an item deleted after the snapshot", %{conn: conn} do
    items = movies(55)
    gone = Enum.at(items, 51)

    {:ok, view, _html} = live(conn, ~p"/movies")
    Repo.delete!(Repo.get!(MediaItem, gone.id))

    render_hook(view, "load_more", %{})

    refute has_element?(view, "#media_items-#{gone.id}")
    assert has_element?(view, "#media_items-#{List.last(items).id}")
  end

  test "Clear filters shows only when filtered and resets to the bare path", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies")
    refute has_element?(view, "#library-reset-filters")

    {:ok, view, _html} = live(conn, ~p"/movies?progress=missing&q=fern")
    assert has_element?(view, "#library-reset-filters")

    view |> element("#library-reset-filters") |> render_click()

    assert_patch(view, "/movies")
    refute has_element?(view, "#library-reset-filters")
  end

  test "params do not carry over from /movies to /tv", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/movies?progress=missing")

    render_patch(view, ~p"/tv")

    assert has_element?(view, "select[name=progress] option[value=''][selected]")
  end
end
