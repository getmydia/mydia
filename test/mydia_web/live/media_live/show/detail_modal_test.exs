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

    # The dialog now fetches its own rail for whatever it opens over (this
    # task), so the recommended title's own recommendations need warming too,
    # even though these tests only assert on the dialog opening, not on its
    # rail. Left unwarmed, that lookup reaches the real relay and the run
    # fails on the network-escape check in test_helper.exs.
    warm_recommendations_cache(recommended_tmdb_id, :movie, [])

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

  test "the dialog carries its own recommendations rail", %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()
    second_hop_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => recommended_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    warm_recommendations_cache(recommended_tmdb_id, :movie, [
      %{"id" => second_hop_tmdb_id, "title" => "Ninth Tide", "release_date" => "2015-08-03"}
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    assert has_element?(view, "#media-detail-modal-rail")
    assert render(view) =~ "Ninth Tide"
  end

  test "hopping to a title in the dialog's own rail swaps the dialog", %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()
    second_hop_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => recommended_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    warm_recommendations_cache(recommended_tmdb_id, :movie, [
      %{"id" => second_hop_tmdb_id, "title" => "Ninth Tide", "release_date" => "2015-08-03"}
    ])

    warm_recommendations_cache(second_hop_tmdb_id, :movie, [])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    view
    |> element(
      ~s(#media-detail-modal-rail div[phx-click="show_details"][phx-value-id="#{second_hop_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    # Not a title assertion: MetadataStubProvider's fetch_by_id/3 returns the
    # same canned "Stub Movie" for any provider_id, and TrendingDetailModal
    # prefers loaded metadata's title over the SearchResult's own once that
    # fetch lands (see title/2), so the header text is identical across every
    # title this dialog ever opens over. The add button's phx-value-tmdb_id
    # is read straight off @item rather than @metadata, so it is what proves
    # the dialog actually swapped to the second-hop title rather than staying
    # on the first.
    assert has_element?(view, "#media-detail-modal[open]")

    assert has_element?(
             view,
             ~s(#media-detail-modal button[phx-click="add_selected_item"][phx-value-tmdb_id="#{second_hop_tmdb_id}"])
           )
  end

  test "adding a title from the dialog's own rail keeps its poster inside the dialog",
       %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()
    dialog_pick_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => recommended_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    warm_recommendations_cache(recommended_tmdb_id, :movie, [
      %{"id" => dialog_pick_tmdb_id, "title" => "Ninth Tide", "release_date" => "2015-08-03"}
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    assert has_element?(
             view,
             ~s(#media-detail-modal-rail div[phx-click="show_details"][phx-value-id="#{dialog_pick_tmdb_id}"])
           )

    view
    |> element(
      # The visible label is "Add"; "Add to Library" lives in title/aria-label
      # since #673 stopped the card button wrapping to two lines.
      ~s(#media-detail-modal-rail button[phx-click="add_selected_item"][phx-value-tmdb_id="#{dialog_pick_tmdb_id}"]),
      "Add"
    )
    |> render_click()

    render_async(view, 5000)

    # The regression this guards: RecommendationEvents.mark_owned/3 used to
    # stamp :navigate on every rail it touched, including the one inside the
    # dialog. DiscoverComponents.trending_card/1 checks @navigate before
    # @on_select, so the poster would have become a plain link to the new
    # title's own page. Clicking it would leave the page and close the dialog
    # out from under the user, instead of re-opening the dialog over that
    # title.
    assert has_element?(
             view,
             ~s(#media-detail-modal-rail div[phx-click="show_details"][phx-value-id="#{dialog_pick_tmdb_id}"])
           )

    refute has_element?(view, ~s(#media-detail-modal-rail a[href^="/media/"]))
  end

  test "a guest requesting a title from inside the dialog's own rail creates the request",
       %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    recommended_tmdb_id = unique_provider_id()
    dialog_only_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id
      })

    warm_recommendations_cache(source_tmdb_id, :movie, [
      %{"id" => recommended_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    warm_recommendations_cache(recommended_tmdb_id, :movie, [
      %{"id" => dialog_only_tmdb_id, "title" => "Ninth Tide", "release_date" => "2015-08-03"}
    ])

    conn = log_in_user(conn, user_fixture(%{role: "guest"}))

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(
      ~s(#recommendations-rail div[phx-click="show_details"][phx-value-id="#{recommended_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    # dialog_only_tmdb_id lives only in :selected_recommendations, never in
    # this page's own :recommendations. Regression: request_recommendation/2
    # used to search only :recommendations, so a guest's Request click on a
    # card reached only through the dialog's own rail fell into the nil branch
    # and silently did nothing. Mirrors the fix Discover already shipped for
    # its own modal, see the comment on its `{:request_media, ...}` clause.
    view
    |> element(
      ~s(#media-detail-modal-rail button[phx-click="request_selected_item"][phx-value-tmdb_id="#{dialog_only_tmdb_id}"]),
      "Request"
    )
    |> render_click()

    assert [request] = Mydia.MediaRequests.list_requests(status: "pending")
    assert request.tmdb_id == dialog_only_tmdb_id
    assert request.title == "Ninth Tide"
  end

  test "adding a missing franchise entry from inside the dialog refreshes its header",
       %{conn: conn} do
    source_tmdb_id = unique_provider_id()
    collection_id = unique_provider_id()
    missing_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "Harrow Lane",
        year: 2021,
        tmdb_id: source_tmdb_id,
        metadata: %{
          "provider_id" => to_string(source_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "Harrow Lane",
          "collection_id" => collection_id,
          "collection_name" => "Vault Chronicles Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => source_tmdb_id, "title" => "Harrow Lane", "release_date" => "2021-03-01"},
      %{"id" => missing_tmdb_id, "title" => "Salt Verge", "release_date" => "2019-04-11"}
    ])

    # The page's own recommendations rail (any movie/show with a tmdb_id starts
    # this lookup on connect) and the dialog's own rail for whatever it opens
    # over both need warming, same reasoning as movie_with_recommendation/1.
    warm_recommendations_cache(source_tmdb_id, :movie, [])
    warm_recommendations_cache(missing_tmdb_id, :movie, [])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    view
    |> element(~s(#franchise-section-item-#{missing_tmdb_id} div[phx-click="show_details"]))
    |> render_click()

    render_async(view, 5000)

    assert has_element?(
             view,
             ~s(#media-detail-modal button[phx-click="add_selected_item"][phx-value-tmdb_id="#{missing_tmdb_id}"])
           )

    view
    |> element(
      ~s(#media-detail-modal button[phx-click="add_selected_item"][phx-value-tmdb_id="#{missing_tmdb_id}"])
    )
    |> render_click()

    render_async(view, 5000)

    # Regression: DetailModalEvents.item_lists(socket) was an argument
    # expression inside the pipeline that assigns :franchise, so it was
    # evaluated against that function's own `socket` parameter, which still
    # carried the pre-add franchise. The dialog's header kept offering "Add to
    # Library" for a title that had just been added from inside it.
    refute has_element?(view, ~s(#media-detail-modal button[phx-click="add_selected_item"]))
    assert has_element?(view, "#trending-detail-modal-actions a", "Go to Movie")
  end
end
