defmodule MydiaWeb.MediaLive.Show.RailPickerHostTest do
  @moduledoc """
  The detail page's rails offer a library picker, and its single page-level
  dialog routes to the correct rail.
  """

  # Connected LiveView tests must stay sync: the Postgres sandbox is only
  # shared with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp movie_with_recommendation do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Aftersun",
        year: 2022,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => recommended_tmdb_id,
        "title" => "The Eternal Daughter",
        "release_date" => "2022-12-02",
        "poster_path" => "/p.jpg"
      }
    ])

    warm_movie_details_cache(source_tmdb_id)

    {movie, recommended_tmdb_id}
  end

  test "a rail card offers the picker when several libraries are configured", %{conn: conn} do
    library_path_fixture(%{path: "/media/host-a", type: "movies"})
    library_path_fixture(%{path: "/media/host-b", type: "movies"})

    {movie, _recommended} = movie_with_recommendation()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#recommendations-rail [data-test='library-picker-caret']")
  end

  test "a single-library install gets no caret", %{conn: conn} do
    library_path_fixture(%{path: "/media/host-only", type: "movies"})

    {movie, _recommended} = movie_with_recommendation()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    refute has_element?(view, "#recommendations-rail [data-test='library-picker-caret']")
  end

  test "opening the picker renders the dialog with both libraries", %{conn: conn} do
    library_path_fixture(%{path: "/media/host-a", type: "movies"})
    library_path_fixture(%{path: "/media/host-b", type: "movies"})

    {movie, recommended} = movie_with_recommendation()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    html =
      view
      |> element("#recommendations-rail [data-test='library-picker-caret']")
      |> render_click()

    assert html =~ "Add to which library?"
    assert html =~ "host-a"
    assert html =~ "host-b"
    assert view |> element("#library-picker-dialog") |> has_element?()
  end

  test "cancelling closes the dialog", %{conn: conn} do
    library_path_fixture(%{path: "/media/host-a", type: "movies"})
    library_path_fixture(%{path: "/media/host-b", type: "movies"})

    {movie, _recommended} = movie_with_recommendation()

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element("#recommendations-rail [data-test='library-picker-caret']")
    |> render_click()

    html = render_click(view, "close_library_picker", %{})

    refute html =~ "Add to which library?"
  end
end
