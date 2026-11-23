defmodule MydiaWeb.MediaLive.Show.AvailabilityTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only
  # shared with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  setup %{conn: conn} do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)

    release_date = Date.add(Date.utc_today(), 30)

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Copper Weather #{System.unique_integer([:positive])}",
        year: 2031,
        metadata: %MediaMetadata{
          provider_id: "9101",
          provider: :tmdb,
          media_type: :movie,
          title: "Copper Weather",
          release_date: release_date
        }
      })

    put_global("released")

    %{conn: log_in_user(conn, admin_user_fixture()), movie: movie, release_date: release_date}
  end

  defp put_global(level) do
    config = Mydia.Config.get()
    media = struct(config.media, minimum_availability: level)
    Application.put_env(:mydia, :runtime_config, %{config | media: media})
  end

  defp open_modal(conn, movie) do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    view |> element("#availability-row") |> render_click()
    view
  end

  defp stored(movie), do: Mydia.Repo.get!(MediaItem, movie.id).minimum_availability

  test "the row shows when automatic search starts", %{
    conn: conn,
    movie: movie,
    release_date: release_date
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    eligible = MydiaWeb.MediaLive.Show.Formatters.format_date(Date.add(release_date, 90))
    assert has_element?(view, "#availability-row", "Search Starts")
    assert has_element?(view, "#availability-row", eligible)
  end

  test "TV shows have no row", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "Copper Weather Stories"})
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#availability-row")
  end

  test "choosing a level stores it and closes the modal", %{conn: conn, movie: movie} do
    view = open_modal(conn, movie)
    assert has_element?(view, "#availability-option-default.active")

    view |> element("#availability-option-in_cinemas") |> render_click()

    refute has_element?(view, "#availability-modal")
    assert stored(movie) == "in_cinemas"
  end

  test "the server default option clears the override", %{conn: conn, movie: movie} do
    {:ok, _} =
      Mydia.Media.update_media_item(Mydia.Accounts.Scope.unrestricted(), movie, %{
        minimum_availability: "announced"
      })

    view = open_modal(conn, movie)
    assert has_element?(view, "#availability-option-announced.active")

    view |> element("#availability-option-default") |> render_click()

    assert stored(movie) == nil
  end

  test "a level equal to the global one is still the movie's own", %{conn: conn, movie: movie} do
    view = open_modal(conn, movie)
    view |> element("#availability-option-released") |> render_click()

    assert stored(movie) == "released"

    put_global("announced")
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    refute has_element?(view, "#availability-row", "Now")
  end
end
