defmodule MydiaWeb.SearchLive.StreamingTest do
  # async: false is required. Connected LiveView tests deadlock under the
  # Postgres sandbox when run concurrently.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.SettingsFixtures

  alias Mydia.Indexers.Structs.IndexerProgress

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  defp search_result(title) do
    %Mydia.Indexers.SearchResult{
      title: title,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "Fast",
      size: 8_000_000_000,
      seeders: 100,
      leechers: 2
    }
  end

  # handle_params/3 always kicks off a REAL background search (that's the
  # point of Task 6: a remount re-runs the search instead of blanking). Left
  # pointed at a real host, that search's own completion races the synthetic
  # :indexer_search_started / :indexer_progress messages the tests inject
  # below and can clobber them via the authoritative handle_async(:search,
  # ...) completion before assertions run. Pointing every indexer at a
  # Bypass server that never answers within the test's lifetime removes the
  # race entirely.
  defp pending_indexer_fixture(name) do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
      # Bypass.pass/1 first: the test ends (and its connection is torn down)
      # long before the sleep elapses. Without marking the expectation
      # passed, Bypass's on_exit verification would report the abandoned
      # connection as a test crash.
      Bypass.pass(bypass)
      Process.sleep(3_000)
      Plug.Conn.resp(conn, 200, "[]")
    end)

    indexer_config_fixture(%{
      name: name,
      type: :prowlarr,
      base_url: "http://localhost:#{bypass.port}"
    })
  end

  test "results from one indexer render while another is still pending", %{conn: conn} do
    pending_indexer_fixture("fast-indexer")
    pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")

    fast = %IndexerProgress{
      indexer: "fast-indexer",
      indexer_id: "fast-id",
      status: :ok,
      results: [search_result("Dune.2021.1080p.BluRay")],
      result_count: 1,
      duration_ms: 800,
      completed: 1,
      total: 2
    }

    pending = %IndexerProgress{
      indexer: "slow-indexer",
      indexer_id: "slow-id",
      status: :pending,
      total: 2
    }

    # Drive handle_params so the LiveView is mid-search with a known search_id.
    render_patch(view, ~p"/search?q=Dune")

    send(view.pid, {:indexer_search_started, current_search_id(view), [fast_pending(), pending]})
    send(view.pid, {:indexer_progress, current_search_id(view), fast})

    html = render(view)

    assert html =~ "Dune.2021.1080p.BluRay"
    assert has_element?(view, "#indexer-status-fast-id")
    assert has_element?(view, "#indexer-status-slow-id")
  end

  defp fast_pending do
    %IndexerProgress{
      indexer: "fast-indexer",
      indexer_id: "fast-id",
      status: :pending,
      total: 2
    }
  end

  defp current_search_id(view) do
    :sys.get_state(view.pid).socket.assigns.search_id
  end

  test "progress from a superseded search is ignored", %{conn: conn} do
    indexer_config_fixture(%{name: "fast-indexer", type: :prowlarr})

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")

    stale = %IndexerProgress{
      indexer: "old-indexer",
      indexer_id: "old-id",
      status: :ok,
      results: [search_result("Stale.Result.From.Old.Search")],
      result_count: 1,
      duration_ms: 100,
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view) - 1, stale})

    html = render(view)

    refute html =~ "Stale.Result.From.Old.Search"
    refute has_element?(view, "#indexer-status-old-id")
  end

  test "submitting a search pushes the query into the URL", %{conn: conn} do
    indexer_config_fixture(%{name: "fast-indexer", type: :prowlarr})

    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> element("#indexer-search-form")
    |> render_submit(%{"search" => "Dune"})

    assert_patched(view, ~p"/search?q=Dune")
  end
end
