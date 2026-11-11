defmodule MydiaWeb.DiscoverLive.DuplicatePagesTest do
  # Connected LiveView tests cannot be async on the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult

  # TMDB ranks these lists by popularity, and each page is fetched (and cached
  # upstream) on its own. When the ranking shifts between two page fetches, a
  # title near the boundary lands on both pages (#1378).
  setup %{conn: conn} do
    warm_genre_cache(:movie, [])

    first = result("Lantern Orchard")
    shared = result("Velvet Meridian")
    last = result("Copper Tideline")

    Cache.put("curated:trending:movie:1", %{results: [first, shared], page: 1, total_pages: 2})
    Cache.put("curated:trending:movie:2", %{results: [shared, last], page: 2, total_pages: 2})

    on_exit(fn ->
      Cache.delete("curated:trending:movie:1")
      Cache.delete("curated:trending:movie:2")
    end)

    %{conn: log_in_user(conn, create_admin_user())}
  end

  test "a title repeated on the next page is shown once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    render_hook(view, "load_more", %{})

    titles =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#discover-grid h3")
      |> Enum.map(&LazyHTML.text/1)
      |> Enum.map(&String.trim/1)

    assert titles == ["Lantern Orchard", "Velvet Meridian", "Copper Tideline"]
  end

  defp result(title) do
    %SearchResult{
      provider_id: to_string(unique_provider_id()),
      provider: :metadata_relay,
      media_type: :movie,
      title: title
    }
  end
end
