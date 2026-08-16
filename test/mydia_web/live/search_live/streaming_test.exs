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

  defp search_result(title, opts \\ []) do
    %Mydia.Indexers.SearchResult{
      title: title,
      download_url:
        Keyword.get(opts, :download_url, "magnet:?xt=urn:btih:#{:erlang.phash2(title)}"),
      indexer: Keyword.get(opts, :indexer, "Fast"),
      size: 8_000_000_000,
      seeders: Keyword.get(opts, :seeders, 100),
      leechers: 2
    }
  end

  # Mirrors the private MydiaWeb.SearchLive.Index.generate_result_id/1 so
  # tests can assert on real result rows by DOM id instead of raw HTML text,
  # per this project's standard of asserting against element ids.
  defp result_dom_id(result) do
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{hash}"
  end

  # handle_params/3 always kicks off a REAL background search (that's the
  # point of Task 6: a remount re-runs the search instead of blanking). Left
  # pointed at a real host, that search's own completion races the synthetic
  # progress messages the tests inject below and can clobber them via the
  # authoritative handle_async(:search, ...) completion before assertions
  # run. Pointing every indexer at a Bypass server that never answers within
  # the test's lifetime removes that completion race entirely.
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

  # search_all/2's on_start callback fires before any HTTP request -- right
  # after the DB query for indexer configs -- so it is NOT delayed by the
  # Bypass sleep above. handle_info({:indexer_search_started, ...}) does a
  # full assign REPLACE of indexer_progress, not a merge. If that real,
  # DB-backed message landed between two synthetic sends keyed by invented
  # ids, it would silently wipe them (a second, earlier race than the
  # completion race above). Waiting for it here, then keying synthetic
  # progress to the SAME real indexer ids, turns the later
  # handle_info({:indexer_progress, ...}) into a Map.put merge instead of a
  # colliding replace, removing the race entirely rather than narrowing it.
  defp wait_for_indexer_progress(view, retries \\ 50)

  defp wait_for_indexer_progress(_view, 0) do
    flunk("timed out waiting for the real on_start message to populate indexer_progress")
  end

  defp wait_for_indexer_progress(view, retries) do
    case :sys.get_state(view.pid).socket.assigns.indexer_progress do
      progress when progress == %{} ->
        Process.sleep(10)
        wait_for_indexer_progress(view, retries - 1)

      progress ->
        progress
    end
  end

  defp current_search_id(view) do
    :sys.get_state(view.pid).socket.assigns.search_id
  end

  test "results from one indexer render while another is still pending", %{conn: conn} do
    fast_indexer = pending_indexer_fixture("fast-indexer")
    slow_indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")

    render_patch(view, ~p"/search?q=Dune")

    # Let the real on_start land (keyed to fast_indexer.id and
    # slow_indexer.id) before sending anything synthetic.
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2021.1080p.BluRay")

    fast = %IndexerProgress{
      indexer: "fast-indexer",
      indexer_id: fast_indexer.id,
      status: :ok,
      results: [dune],
      result_count: 1,
      duration_ms: 800,
      completed: 1,
      total: 2
    }

    send(view.pid, {:indexer_progress, current_search_id(view), fast})

    render(view)

    assert has_element?(view, "##{result_dom_id(dune)}")
    assert has_element?(view, "#indexer-status-#{fast_indexer.id}")
    assert has_element?(view, "#indexer-status-#{slow_indexer.id}")
  end

  test "progress from a superseded search is ignored", %{conn: conn} do
    pending_indexer_fixture("fast-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")

    stale_result = search_result("Dune.Stale.Result.From.Old.Search")

    stale = %IndexerProgress{
      indexer: "old-indexer",
      indexer_id: "old-id",
      status: :ok,
      results: [stale_result],
      result_count: 1,
      duration_ms: 100,
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view) - 1, stale})

    render(view)

    refute has_element?(view, "##{result_dom_id(stale_result)}")
    refute has_element?(view, "#indexer-status-old-id")
  end

  # Confirms the two refutations above are not vacuously true (i.e. the
  # element selectors themselves are correct and would catch a regression):
  # apply the exact same stale progress with a search_id that DOES match the
  # current search, and assert the result and status chip now DO appear.
  test "a matching (non-stale) search_id does surface the same content", %{conn: conn} do
    pending_indexer_fixture("fast-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")
    wait_for_indexer_progress(view)

    result = search_result("Dune.Stale.Result.From.Old.Search")

    progress = %IndexerProgress{
      indexer: "old-indexer",
      indexer_id: "old-id",
      status: :ok,
      results: [result],
      result_count: 1,
      duration_ms: 100,
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view), progress})

    render(view)

    assert has_element?(view, "##{result_dom_id(result)}")
    assert has_element?(view, "#indexer-status-old-id")
  end

  test "submitting a search pushes the query into the URL", %{conn: conn} do
    pending_indexer_fixture("fast-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")

    view
    |> element("#indexer-search-form")
    |> render_submit(%{"search" => "Dune"})

    assert_patched(view, ~p"/search?q=Dune")
  end
end
