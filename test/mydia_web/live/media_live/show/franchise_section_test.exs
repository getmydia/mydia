defmodule MydiaWeb.MediaLive.Show.FranchiseSectionTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a TV show page never renders the franchise section", %{conn: conn} do
    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "A Show",
        year: 2010,
        tmdb_id: unique_provider_id()
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#franchise-section")
  end

  test "a movie whose franchise resolves renders the strip with its owned count",
       %{conn: conn} do
    collection_id = unique_provider_id()
    owned_tmdb_id = unique_provider_id()
    missing_tmdb_id = unique_provider_id()

    movie =
      media_item_fixture(%{
        type: "movie",
        title: "First",
        year: 2001,
        tmdb_id: owned_tmdb_id,
        metadata: %{
          "provider_id" => to_string(owned_tmdb_id),
          "provider" => "metadata_relay",
          "media_type" => "movie",
          "title" => "First",
          "collection_id" => collection_id,
          "collection_name" => "Test Collection"
        }
      })

    warm_collection_cache(collection_id, [
      %{"id" => owned_tmdb_id, "title" => "First", "release_date" => "2001-01-01"},
      %{"id" => missing_tmdb_id, "title" => "Second", "release_date" => "2004-01-01"}
    ])

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_async(view, 5000)

    assert has_element?(view, "#franchise-section")
    assert has_element?(view, "#franchise-section .badge", "1 of 2")
    assert has_element?(view, "#franchise-section-item-#{owned_tmdb_id}")
    assert has_element?(view, "#franchise-section-item-#{missing_tmdb_id}")

    # `can_create_media` reaches the component: an admin gets the add affordance
    # on the missing entry. The id lives on the rail's item wrapper; phx-click
    # is on the trending_card_action button nested inside it, hence the
    # descendant combinator rather than a compound selector.
    assert has_element?(
             view,
             "#franchise-section-item-#{missing_tmdb_id} [phx-click='add_franchise_movie']"
           )
  end
end
