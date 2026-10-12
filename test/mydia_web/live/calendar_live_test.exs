defmodule MydiaWeb.CalendarLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  @movie_entry ~s{button[phx-click="view_item"][phx-value-type="movie"]}
  @episode_entry ~s{button[phx-click="view_item"][phx-value-type="episode"]}

  setup %{conn: conn} do
    today = Date.utc_today()

    media_item_fixture(%{
      type: "movie",
      title: "Harbor of Quiet Lanterns",
      metadata: %{
        provider_id: "9001",
        provider: :metadata_relay,
        media_type: :movie,
        release_date: today
      }
    })

    show = media_item_fixture(%{type: "tv_show", title: "The Copper Orchard"})
    episode_fixture(%{media_item_id: show.id, air_date: today, title: "Seedfall"})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp filter(view, type) do
    view |> element("#calendar-filter-form") |> render_change(%{"type" => type})
  end

  test "the type select sits inside a form, so the browser can send its change", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    assert has_element?(view, "#calendar-filter-form select[name=type]")
  end

  test "shows both kinds by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    assert has_element?(view, @movie_entry)
    assert has_element?(view, @episode_entry)
  end

  test "Movies hides episodes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    filter(view, "movie")

    assert has_element?(view, @movie_entry)
    refute has_element?(view, @episode_entry)
  end

  test "TV Shows hides movies", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    filter(view, "tv_show")

    refute has_element?(view, @movie_entry)
    assert has_element?(view, @episode_entry)
  end

  test "All Media brings both back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/calendar")

    filter(view, "movie")
    filter(view, "all")

    assert has_element?(view, @movie_entry)
    assert has_element?(view, @episode_entry)
  end
end
