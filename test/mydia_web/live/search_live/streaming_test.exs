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

  # Like pending_indexer_fixture/1, but the HTTP call is held open until the
  # test explicitly releases it with open_gate/1 (rather than parked past the
  # test's lifetime). That turns "the full search completes AFTER a retry's
  # result is already on screen" from a race into a deterministic ordering:
  # the search provably cannot finish while the gate is shut.
  defp gated_indexer_fixture(name) do
    bypass = Bypass.open()
    {:ok, gate} = Agent.start_link(fn -> false end)

    Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
      Bypass.pass(bypass)
      await_gate(gate)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "[]")
    end)

    config =
      indexer_config_fixture(%{
        name: name,
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}"
      })

    {config, gate}
  end

  defp open_gate(gate), do: Agent.update(gate, fn _ -> true end)

  # Bounded on purpose: a gate that is never opened must surface as a failed
  # assertion in the test, never as a hung suite.
  defp await_gate(gate, retries \\ 500)
  defp await_gate(_gate, 0), do: :ok

  defp await_gate(gate, retries) do
    if Agent.get(gate, & &1) do
      :ok
    else
      Process.sleep(10)
      await_gate(gate, retries - 1)
    end
  end

  defp wait_until_search_finished(view, retries \\ 300)

  defp wait_until_search_finished(_view, 0) do
    flunk("timed out waiting for handle_async(:search, ...) to clear :searching")
  end

  defp wait_until_search_finished(view, retries) do
    if :sys.get_state(view.pid).socket.assigns.searching do
      Process.sleep(10)
      wait_until_search_finished(view, retries - 1)
    else
      :ok
    end
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

  # From search start until the first indexer reports, the display set is
  # genuinely empty: the spinner must be up and the results card (which would
  # read "0 results for Dune") must not be rendered at all. Starting
  # :results_empty? at false inverts both gates -- `@searching &&
  # @results_empty?` suppresses the spinner while `!@results_empty?` shows the
  # card -- so the user's first impression of every search is "0 results",
  # which is exactly the failure this branch set out to fix.
  #
  # The indexer is parked behind a Bypass that sleeps past this test's
  # lifetime, so neither on_indexer_result nor handle_async can land: the
  # state under assertion is the fresh-search state and it stays put.
  test "a fresh search shows the spinner, not a zero-result card", %{conn: conn} do
    pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")

    render_patch(view, ~p"/search?q=Dune")

    assert has_element?(view, "#search-loading-state")
    refute has_element?(view, "#search-results-count")
  end

  # Positive control for the refutation above: once an indexer reports
  # results, the card appears and the spinner goes away. Without this, a
  # passing refute could just mean "#search-results-count" never renders under
  # any circumstance.
  test "the results card appears once an indexer reports", %{conn: conn} do
    indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2021.1080p.BluRay")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "slow-indexer",
         indexer_id: indexer.id,
         status: :ok,
         results: [dune],
         result_count: 1,
         duration_ms: 800,
         completed: 1,
         total: 1
       }}
    )

    render(view)

    assert has_element?(view, "#search-results-count")
    refute has_element?(view, "#search-loading-state")
  end

  # A result that reached the display set through on_indexer_result but is NOT
  # in the full search's aggregate return value is exactly what a
  # single-indexer retry produces: the retry runs under its own start_async
  # key ({:retry, id}), so its releases only ever arrive as progress messages
  # and never appear in the aggregate that handle_async(:search, ...)
  # receives. Injecting one directly models that precisely, and avoids
  # clicking Retry only to have the retry park on the same gated Bypass.
  #
  # This is the ordinary ordering, not an exotic race: the Retry button
  # appears as soon as one indexer errors, while slow indexers are still
  # pending, so a retry against a fast-failing host normally settles well
  # before the slow ones finish. The gate makes that ordering deterministic
  # here.
  test "a result contributed by a retry survives the full search completing", %{conn: conn} do
    {_indexer, gate} = gated_indexer_fixture("gated-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2021.1080p.BluRay")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "retried-indexer",
         indexer_id: "retried-id",
         status: :ok,
         results: [dune],
         result_count: 1,
         duration_ms: 120,
         completed: 1,
         total: 1
       }}
    )

    render(view)

    assert has_element?(view, "##{result_dom_id(dune)}"),
           "precondition failed: the retry's result never made it on screen"

    open_gate(gate)
    wait_until_search_finished(view)

    assert has_element?(view, "##{result_dom_id(dune)}")
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

  # The retry itself starts a real (second) search against the indexer, keyed
  # to the SAME search_id (by design, see the retry_indexer handler). If that
  # indexer resolved fast (e.g. a plain indexer_config_fixture hitting
  # localhost:9696, which fails almost instantly with econnrefused), its own
  # on_indexer_result callback can race the test's post-click assertion and
  # legitimately overwrite the :pending status back to :error before
  # :sys.get_state runs. Using the slow Bypass-backed fixture (like the
  # completion-race avoidance above) keeps the retry's real HTTP call parked
  # well past the test's lifetime, removing that race entirely.
  #
  # A single indexer cannot prove handle_info({:indexer_search_started, ...})
  # MERGES rather than REPLACES: with one entry in indexer_progress, "wiped
  # the map down to just this one pending entry" and "correctly updated this
  # one entry to pending" are indistinguishable. A second entry ("succeeded-
  # id") makes the two hypotheses diverge. It is deliberately NOT backed by a
  # real indexer_config (same pattern as the "old-indexer"/"old-id" entries
  # used elsewhere in this file), so it can never appear in any real
  # on_start's pending list -- exactly mirroring an indexer that already
  # finished and is NOT part of the scoped retry. Retrying "flaky-indexer"
  # sends a real, scoped on_start covering only flaky-indexer; a REPLACE-
  # based handler would wipe "succeeded-id" out of indexer_progress the
  # moment that real message lands, a MERGE-based one preserves it.
  test "retrying a failed indexer marks it pending again without wiping other indexers", %{
    conn: conn
  } do
    indexer = pending_indexer_fixture("flaky-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")
    wait_for_indexer_progress(view)

    succeeded = %IndexerProgress{
      indexer: "succeeded-indexer",
      indexer_id: "succeeded-id",
      status: :ok,
      results: [],
      result_count: 3,
      duration_ms: 500,
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view), succeeded})

    failed = %IndexerProgress{
      indexer: "flaky-indexer",
      indexer_id: indexer.id,
      status: :error,
      error: "Connection failed: :econnrefused",
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view), failed})

    assert has_element?(view, "#indexer-status-#{indexer.id} button")

    view
    |> element("#indexer-status-#{indexer.id} button")
    |> render_click()

    # The retry's own real on_start fires before any HTTP request (same
    # timing as the initial search's on_start above, which wait_for_indexer_
    # progress/1 confirms lands within tens of ms in this suite), so this
    # short wait reliably outlasts it before we inspect final state.
    Process.sleep(200)

    progress = :sys.get_state(view.pid).socket.assigns.indexer_progress

    assert progress[indexer.id].status == :pending
    assert progress["succeeded-id"].status == :ok
    assert progress["succeeded-id"].result_count == 3
  end

  # Before this task, no handle_event("retry_indexer", ...) clause existed
  # anywhere in the LiveView, so clicking Retry raised a FunctionClauseError
  # and crashed the process. render_click/1 re-raises that crash in the test
  # process, so simply completing the click and then successfully rendering
  # the view again is direct proof the crash is gone.
  test "retrying a failed indexer does not crash the LiveView", %{conn: conn} do
    indexer = pending_indexer_fixture("flaky-indexer")

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")
    wait_for_indexer_progress(view)

    failed = %IndexerProgress{
      indexer: "flaky-indexer",
      indexer_id: indexer.id,
      status: :error,
      error: "Connection failed: :econnrefused",
      completed: 1,
      total: 1
    }

    send(view.pid, {:indexer_progress, current_search_id(view), failed})

    view
    |> element("#indexer-status-#{indexer.id} button")
    |> render_click()

    assert Process.alive?(view.pid)
    assert render(view) =~ "flaky-indexer"
  end
end
