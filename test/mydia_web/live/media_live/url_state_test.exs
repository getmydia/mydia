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

  test "the upcoming progress filter shows only unreleased items", %{conn: conn} do
    soon =
      media_item_fixture(%{
        type: "movie",
        title: "Pale Horizon",
        metadata: %{release_date: Date.add(Date.utc_today(), 45)}
      })

    out = media_item_fixture(%{type: "movie", title: "Worn Compass"})

    {:ok, view, _html} = live(conn, ~p"/movies?progress=upcoming")

    assert has_element?(view, "#media_items-#{soon.id}")
    refute has_element?(view, "#media_items-#{out.id}")
    assert has_element?(view, "select[name=progress] option[value=upcoming][selected]")
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

  test "load_more past the cap keeps shown at what Back can restore", %{conn: conn} do
    movies(1010)

    {:ok, view, _html} = live(conn, ~p"/movies?shown=1000")
    render_hook(view, "load_more", %{})

    assert_patch(view, "/movies?shown=1000")
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

  describe "remembered sort and filters" do
    defp choose(view, sort_by, progress) do
      view
      |> element("#library-filter-form")
      |> render_change(%{
        "progress" => progress,
        "monitored" => "all",
        "quality" => "",
        "sort_by" => sort_by
      })
    end

    test "a bare visit restores the page's last sort and filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/movies")
      choose(view, "year_desc", "missing")
      assert_patch(view, "/movies?progress=missing&sort=year_desc")

      # The restore also patches the URL, but that patch rides in the join
      # reply, which the test client drops, so assert_patch cannot see it.
      {:ok, view, _html} = live(conn, ~p"/movies")

      assert has_element?(
               view,
               "#library-filter-form select[name=sort_by] option[selected][value=year_desc]"
             )
    end

    test "each page remembers its own state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/movies")
      choose(view, "year_desc", "missing")

      {:ok, view, _html} = live(conn, ~p"/tv")

      refute has_element?(
               view,
               "#library-filter-form select[name=sort_by] option[selected][value=year_desc]"
             )
    end

    test "sort and filters in the URL win over the saved state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/movies")
      choose(view, "year_desc", "missing")

      {:ok, view, _html} = live(conn, ~p"/movies?sort=added_desc")

      assert has_element?(
               view,
               "#library-filter-form select[name=sort_by] option[selected][value=added_desc]"
             )

      refute has_element?(
               view,
               "#library-filter-form select[name=progress] option[selected][value=missing]"
             )
    end

    test "Clear filters forgets the saved state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/movies")
      choose(view, "year_desc", "missing")
      view |> element("#library-reset-filters") |> render_click()

      {:ok, view, _html} = live(conn, ~p"/movies")

      refute has_element?(
               view,
               "#library-filter-form select[name=sort_by] option[selected][value=year_desc]"
             )
    end

    test "searching does not save anything", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/movies")
      view |> element("#library-search-form") |> render_change(%{"search" => "fern"})

      assert Mydia.Accounts.library_listing_state(user, "movies") == %{}
    end

    test "searching a page whose URL overrides the saved state keeps the saved state",
         %{conn: conn, user: user} do
      :ok = Mydia.Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})

      {:ok, view, _html} = live(conn, ~p"/movies?sort=added_desc")
      view |> element("#library-search-form") |> render_change(%{"search" => "fern"})

      assert Mydia.Accounts.library_listing_state(user, "movies") == %{"sort" => "year_desc"}
    end

    test "Clear filters on a page whose URL overrides the saved state forgets it",
         %{conn: conn, user: user} do
      :ok = Mydia.Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})

      {:ok, view, _html} = live(conn, ~p"/movies?sort=added_desc")
      view |> element("#library-reset-filters") |> render_click()

      assert Mydia.Accounts.library_listing_state(user, "movies") == %{}
    end

    test "Clear filters forgets the saved state even when the URL shows the defaults",
         %{conn: conn, user: user} do
      :ok = Mydia.Accounts.put_library_listing_state(user, "movies", %{"sort" => "year_desc"})

      {:ok, view, _html} = live(conn, ~p"/movies?sort=title_asc&q=fern")
      view |> element("#library-reset-filters") |> render_click()

      assert Mydia.Accounts.library_listing_state(user, "movies") == %{}
    end

    test "a live patch to a page with the same restored listing loads that page's rows",
         %{conn: conn, user: user} do
      movie = media_item_fixture(%{type: "movie", title: "Quillmere Drift"})
      show = media_item_fixture(%{type: "tv_show", title: "Harrowfen Lanterns"})
      :ok = Mydia.Accounts.put_library_listing_state(user, "tv_shows", %{"sort" => "year_desc"})

      {:ok, view, _html} = live(conn, ~p"/movies?sort=year_desc")
      assert has_element?(view, "#media_items-#{movie.id}")

      render_patch(view, ~p"/tv")

      assert has_element?(view, "#media_items-#{show.id}")
      refute has_element?(view, "#media_items-#{movie.id}")

      assert has_element?(
               view,
               "#library-filter-form select[name=sort_by] option[selected][value=year_desc]"
             )
    end
  end
end
