defmodule MydiaWeb.CollectionLive.ShowPostersTest do
  # async: false, a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Collections
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @poster_src "https://image.tmdb.org/t/p/w342/alt.jpg"

  setup %{conn: conn} do
    user = user_fixture(%{role: "admin"})

    {:ok, collection} =
      Collections.create_collection(user, %{
        name: "Watchlist",
        type: "manual",
        visibility: "private"
      })

    item = media_item_fixture(%{title: "Zephyr Quest", metadata: %{poster_path: "/meta.jpg"}})

    {:ok, item} =
      item
      |> MediaItem.poster_override_changeset(%{poster_override: "/alt.jpg"})
      |> Repo.update()

    %{conn: log_in_user(conn, user), collection: collection, item: item}
  end

  test "search results in the add-items modal render the item's poster",
       %{conn: conn, collection: collection, item: item} do
    {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

    render_click(view, "open_add_items_modal", %{})
    render_change(view, "search_add_items", %{"search" => "Zephyr"})

    assert has_element?(
             view,
             ~s(#add-items-modal button[phx-value-id="#{item.id}"] img[src="#{@poster_src}"])
           )
  end

  test "an item added to a manual collection renders its poster",
       %{conn: conn, collection: collection, item: item} do
    {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

    render_click(view, "open_add_items_modal", %{})
    render_click(view, "toggle_item_in_collection", %{"id" => item.id})

    assert has_element?(view, ~s(#collection-items img[src="#{@poster_src}"]))
  end
end
