defmodule MydiaWeb.MediaLive.Show.FranchiseSectionTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "a TV show page never renders the franchise section", %{conn: conn} do
    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "A Show",
        year: 2010,
        tmdb_id: System.unique_integer([:positive])
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#franchise-section")
  end

  test "a movie whose franchise resolves renders the strip with its owned count",
       %{conn: conn} do
    collection_id = System.unique_integer([:positive])
    owned_tmdb_id = System.unique_integer([:positive])
    missing_tmdb_id = System.unique_integer([:positive])

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

  # Populates the shared metadata cache through the real fetch path, with the
  # relay response coming from Bypass. `fetch_collection_cached/3` keys on the
  # provider type, collection id and language but not the base URL, so the
  # LiveView's own default config reads this entry back without any outbound
  # request: the assertions above passing is itself proof the cache was hit.
  defp warm_collection_cache(collection_id, parts) do
    bypass = Bypass.open()
    relay = Metadata.default_relay_config()
    config = %{relay | base_url: "http://localhost:#{bypass.port}"}

    on_exit(fn ->
      Cache.delete("collection:#{relay.type}:#{collection_id}:#{relay.options.language}")
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      body = %{"id" => collection_id, "name" => "Test Collection", "parts" => parts}

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, _collection} = Metadata.fetch_collection_cached(config, collection_id)
    :ok
  end
end
