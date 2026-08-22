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

  # Mirrors `franchise_section_test.exs`: a movie whose metadata already
  # carries a `collection_id` skips the movie-details pointer lookup, so no
  # warm_movie_details_cache call is needed here. `missing_tmdb_id` is not
  # owned, so its card renders the Add split button the picker hangs off.
  #
  # The recommendations cache is warmed empty so the page's unconditional
  # recommendations load (`RecommendationEvents.maybe_load/1` fires for any
  # movie with a tmdb_id) resolves offline instead of reaching the live relay.
  defp movie_with_franchise_entry do
    collection_id = unique_provider_id()
    own_tmdb_id = unique_provider_id()
    missing_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Alien",
        year: 1979,
        tmdb_id: own_tmdb_id,
        metadata: %{
          "provider_id" => to_string(own_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Alien",
          "collection_id" => collection_id,
          "collection_name" => "Alien Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => own_tmdb_id, "title" => "Alien", "release_date" => "1979-05-25"},
      %{"id" => missing_tmdb_id, "title" => "Aliens", "release_date" => "1986-07-18"}
    ])

    warm_recommendations_cache(own_tmdb_id, :movie, [])

    {movie, missing_tmdb_id}
  end

  # The #460 case: `overlap_tmdb_id` is seeded as both a missing franchise
  # entry and a recommendation, so the same tmdb_id draws a card in both
  # rails at once. The routing decision in `LibraryPickerEvents` is keyed on
  # the tmdb_id alone, not on which rail's caret was clicked.
  defp movie_with_overlapping_entry do
    collection_id = unique_provider_id()
    own_tmdb_id = unique_provider_id()
    overlap_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Alien",
        year: 1979,
        tmdb_id: own_tmdb_id,
        metadata: %{
          "provider_id" => to_string(own_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Alien",
          "collection_id" => collection_id,
          "collection_name" => "Alien Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => own_tmdb_id, "title" => "Alien", "release_date" => "1979-05-25"},
      %{"id" => overlap_tmdb_id, "title" => "Aliens", "release_date" => "1986-07-18"}
    ])

    warm_recommendations_cache(own_tmdb_id, :movie, [
      %{
        "id" => overlap_tmdb_id,
        "title" => "Aliens",
        "release_date" => "1986-07-18",
        "poster_path" => "/p.jpg"
      }
    ])

    {movie, overlap_tmdb_id}
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

    {movie, _recommended} = movie_with_recommendation()

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

  describe "add_from_library_picker/2 routing" do
    test "a recommendation-only title routes the add to the recommendations rail",
         %{conn: conn} do
      library_path_fixture(%{path: "/media/host-a", type: "movies"})
      library_path_fixture(%{path: "/media/host-b", type: "movies"})

      {movie, recommended_tmdb_id} = movie_with_recommendation()

      {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
      render_async(view, 5000)

      view
      |> element(
        "#recommendations-rail-item-#{recommended_tmdb_id} [data-test='library-picker-caret']"
      )
      |> render_click()

      view
      |> element("#library-picker-dialog [data-test='library-picker-option']", "host-a")
      |> render_click()

      # Proof of routing: the recommendations rail registered the in-flight
      # add (its card now shows the spinner) and there is no franchise strip
      # at all to have wrongly claimed it.
      assert has_element?(view, "#recommendations-rail-item-#{recommended_tmdb_id}", "Adding...")
      refute has_element?(view, "#franchise-section")
    end

    test "a movie that is a franchise entry routes the add to the franchise rail",
         %{conn: conn} do
      library_path_fixture(%{path: "/media/host-a", type: "movies"})
      library_path_fixture(%{path: "/media/host-b", type: "movies"})

      {movie, missing_tmdb_id} = movie_with_franchise_entry()

      {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
      render_async(view, 5000)

      view
      |> element("#franchise-section-item-#{missing_tmdb_id} [data-test='library-picker-caret']")
      |> render_click()

      view
      |> element("#library-picker-dialog [data-test='library-picker-option']", "host-a")
      |> render_click()

      assert has_element?(view, "#franchise-section-item-#{missing_tmdb_id}", "Adding...")
    end

    test "a title in both rails (#460) routes to the franchise rail even when the click " <>
           "starts from the recommendations card",
         %{conn: conn} do
      library_path_fixture(%{path: "/media/host-a", type: "movies"})
      library_path_fixture(%{path: "/media/host-b", type: "movies"})

      {movie, overlap_tmdb_id} = movie_with_overlapping_entry()

      {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
      render_async(view, 5000)

      # Both rails render a card for overlap_tmdb_id. Opening the picker from
      # the recommendations card is the point: routing is decided by franchise
      # membership of the tmdb_id, not by which rail's caret fired the event.
      view
      |> element(
        "#recommendations-rail-item-#{overlap_tmdb_id} [data-test='library-picker-caret']"
      )
      |> render_click()

      view
      |> element("#library-picker-dialog [data-test='library-picker-option']", "host-a")
      |> render_click()

      assert has_element?(view, "#franchise-section-item-#{overlap_tmdb_id}", "Adding...")
      refute has_element?(view, "#recommendations-rail-item-#{overlap_tmdb_id}", "Adding...")
    end
  end
end
