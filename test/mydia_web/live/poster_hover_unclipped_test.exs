defmodule MydiaWeb.PosterHoverUnclippedTest do
  @moduledoc """
  `hover-3d` scales and tilts the poster past its card. A card with
  `overflow-hidden` crops that back inside its own border and the hover reads
  as an inner zoom (#1068). The Discover card has never clipped; these pages
  must not either.
  """

  # async: false: a connected LiveView cannot share the PostgreSQL sandbox
  # connection with an async test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Collections

  setup %{conn: conn} do
    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp assert_posters_unclipped(html) do
    doc = LazyHTML.from_fragment(html)

    refute Enum.empty?(LazyHTML.query(doc, ".hover-3d")),
           "expected at least one poster on the page"

    assert Enum.empty?(LazyHTML.query(doc, ".card.overflow-hidden .hover-3d")),
           "a card with overflow-hidden crops the poster hover"
  end

  test "the Movies grid card does not clip its poster", %{conn: conn} do
    media_item_fixture(%{type: "movie", title: "The Lantern Keeper"})

    {:ok, view, _html} = live(conn, ~p"/movies")
    html = render(view)

    assert_posters_unclipped(html)

    doc = LazyHTML.from_fragment(html)

    # The card no longer clips, so the badge row bounds itself: at dense
    # density its nowrap badges would otherwise overrun the card edge.
    refute Enum.empty?(LazyHTML.query(doc, ".card .hover-3d figure.rounded-t-box"))

    refute Enum.empty?(
             LazyHTML.query(doc, ".card .card-body > div > div.min-w-0.overflow-hidden")
           ),
           "the grid card's badge row must bound its own overflow"
  end

  test "the Recently Added card does not clip its poster", %{conn: conn} do
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    movie = media_item_fixture(%{type: "movie", title: "The Lantern Keeper"})
    media_file_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#recently-added-rail-item-#{movie.id}")
    assert_posters_unclipped(render(view))
  end

  test "the collection grid card does not clip its poster", %{conn: conn, user: user} do
    movie = media_item_fixture(%{type: "movie", title: "The Lantern Keeper"})

    {:ok, collection} =
      Collections.create_collection(user, %{
        name: "Shelf",
        type: "manual",
        visibility: "private"
      })

    {:ok, _} = Collections.add_item(collection, movie.id)

    {:ok, view, _html} = live(conn, ~p"/collections/#{collection.id}")

    assert_posters_unclipped(render(view))
  end
end
