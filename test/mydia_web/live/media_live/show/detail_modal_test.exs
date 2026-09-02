defmodule MydiaWeb.MediaLive.Show.DetailModalTest do
  @moduledoc """
  Clicking a poster in the detail page's rails opens the same dialog Discover
  uses, so a recommended title's trailer is reachable without adding it first.

  setup_metadata_stub swaps the provider registry so the dialog's own metadata
  fetch resolves offline. warm_recommendations_cache is unaffected by that swap:
  fetch_recommendations_cached calls the relay module directly rather than going
  through the registry, so the two helpers compose.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # connected LiveView mounts run outside the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers
  import Mydia.MetadataStub

  setup :setup_metadata_stub

  setup %{conn: conn} do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp movie_with_recommendation(recommended_title) do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{
        "id" => recommended_tmdb_id,
        "title" => recommended_title,
        "release_date" => "2019-04-11",
        "poster_path" => "/p.jpg"
      }
    ])

    {movie, recommended_tmdb_id}
  end

  test "clicking a recommended poster opens the dialog", %{conn: conn} do
    {movie, recommended_tmdb_id} = movie_with_recommendation("Salt Verge")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    refute has_element?(view, "#media-detail-modal[open]")

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    assert has_element?(view, "#media-detail-modal[open]")
    assert render(view) =~ "Salt Verge"
  end

  test "closing the dialog leaves the page", %{conn: conn} do
    {movie, recommended_tmdb_id} = movie_with_recommendation("Salt Verge")

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)
    assert has_element?(view, "#media-detail-modal[open]")

    # aria-label disambiguates: TrendingDetailModal always renders two
    # phx-click="close_details" buttons when open (the header's icon-only X and
    # the modal-backdrop button used for click-outside), matching the
    # codebase's idiom for a modal with multiple same-selector buttons (see
    # request_detail_popup_test.exs). Only the header button carries
    # aria-label="Close"; the backdrop button's visible text is lowercase
    # "close" and carries no aria-label.
    view
    |> element(~s(#media-detail-modal button[phx-click="close_details"][aria-label="Close"]))
    |> render_click()

    refute has_element?(view, "#media-detail-modal[open]")
    assert has_element?(view, "#recommendations-rail")
  end

  test "an owned recommendation still links to its own page instead of opening the dialog",
       %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    owned_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    owned =
      media_item_fixture(%{
        type: "movie",
        title: "Salt Verge",
        year: 2019,
        tmdb_id: owned_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => owned_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, ~s(#recommendations-rail a[href="/media/#{owned.id}"]))

    refute has_element?(
             view,
             ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{owned_tmdb_id}"])
           )
  end
end
