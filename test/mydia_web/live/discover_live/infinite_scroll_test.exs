defmodule MydiaWeb.DiscoverLive.InfiniteScrollTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult

  # The grid's next page is requested by the LoadMoreSentinel hook, which
  # LiveViewTest cannot run. render_hook/3 stands in for it. handle_event
  # queues {:load_page, ...} to itself before replying, so the page has
  # landed by the time the next has_element?/2 call reaches the process.

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])
    %{conn: log_in_user(conn, create_admin_user())}
  end

  test "the sentinel asks for more while pages remain", %{conn: conn} do
    seed_curated_page(1, 2, [curated_result(unique_provider_id(), "Paper Comet")])

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-load-more[phx-hook='LoadMoreSentinel']")
    assert has_element?(view, "#discover-load-more[data-has-more='true']")
    assert has_element?(view, "#discover-load-more .loading")
    refute has_element?(view, "#load-more-trigger")
  end

  test "the sentinel goes quiet on the last page", %{conn: conn} do
    seed_curated_page(1, 1, [curated_result(unique_provider_id(), "Paper Comet")])

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-load-more[data-has-more='false']")
    refute has_element?(view, "#discover-load-more .loading")
  end

  test "load_more appends the next page to the grid", %{conn: conn} do
    seed_curated_page(1, 3, [curated_result(unique_provider_id(), "Paper Comet")])
    seed_curated_page(2, 3, [curated_result(unique_provider_id(), "Velvet Static")])

    {:ok, view, _html} = live(conn, ~p"/discover")

    render_hook(view, "load_more", %{})

    assert has_element?(view, "#discover-grid h3", "Paper Comet")
    assert has_element?(view, "#discover-grid h3", "Velvet Static")
    assert has_element?(view, "#discover-load-more[data-has-more='true']")
  end

  test "a failed page shows Retry, stops asking, and Retry loads it", %{conn: conn} do
    seed_curated_page(1, 2, [curated_result(unique_provider_id(), "Paper Comet")])

    # 404 rather than 5xx: the HTTP client retries transient statuses.
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    Bypass.expect_once(bypass, "GET", "/tmdb/movies/trending", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not found"}))
    end)

    {:ok, view, _html} = live(conn, ~p"/discover")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "load_more", %{})

        assert has_element?(view, "#discover-load-more-error")
      end)

    assert log =~ "Failed to load discover results"

    assert has_element?(view, "#discover-load-more-error")
    assert has_element?(view, "#discover-load-more[data-has-more='false']")
    assert has_element?(view, "#discover-grid h3", "Paper Comet")

    # The relay recovers. Seeding the cache serves page 2 without a second
    # request, which expect_once would reject.
    seed_curated_page(2, 2, [curated_result(unique_provider_id(), "Velvet Static")])

    view |> element("#discover-load-more-retry") |> render_click()

    assert has_element?(view, "#discover-grid h3", "Velvet Static")
    refute has_element?(view, "#discover-load-more-error")
  end

  defp seed_curated_page(page, total_pages, results) do
    key = "curated:trending:movie:#{page}"

    Cache.put(key, %{results: results, page: page, total_pages: total_pages},
      ttl: :timer.minutes(30)
    )

    on_exit(fn -> Cache.delete(key) end)
  end

  defp curated_result(id, title) do
    SearchResult.from_api_response(%{"id" => id, "title" => title}, media_type: :movie)
  end
end
