defmodule MydiaWeb.MediaLive.ManualSearchStreamingTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
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

  defp current_search_id(view) do
    :sys.get_state(view.pid).socket.assigns.search_id
  end

  # Mirrors SearchHelpers.generate_positioned_id/1, which MediaLive.Show
  # installs as the :search_results stream's :dom_id, so tests can assert on
  # real result rows by element id instead of raw HTML text. `pos` defaults to
  # 0, the top row, which is where a lone result lands.
  defp positioned_result_dom_id(result, pos \\ 0) do
    hash = :erlang.phash2({result.download_url, result.indexer})
    "search-result-#{String.pad_leading(Integer.to_string(pos), 5, "0")}-#{hash}"
  end

  # Mirrors MydiaWeb.SearchLive.StreamingTest's fixture of the same name: a
  # real indexer whose HTTP call is parked behind a Bypass server that sleeps
  # past the test's lifetime. Retrying an indexer starts a second real search
  # under the SAME search_id (by design), so a fast-resolving indexer (e.g. a
  # plain indexer_config_fixture hitting localhost:9696, which fails almost
  # instantly) can race the test's post-click assertion and legitimately
  # overwrite the status the test is trying to observe. This removes that
  # race entirely rather than narrowing it.
  defp pending_indexer_fixture(name) do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
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
    {:ok, gate} = Agent.start_link(fn -> %{open: false, timed_out: false} end)

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

  defp open_gate(gate), do: Agent.update(gate, &%{&1 | open: true})

  # See MydiaWeb.SearchLive.StreamingTest for the full rationale. In short: a
  # gate that is never opened must surface as a failure, never as a hung suite
  # -- and never as a PASS. This clause used to return :ok, which let the
  # Bypass handler answer anyway, so the search completed normally and the
  # ordering the gated test exists to establish was never established.
  #
  # flunk/1 alone does not fix that: this runs in the Bypass plug process and
  # Bypass.pass/1 has already marked the expectation passed, so the raise is
  # swallowed. The give-up is recorded in the Agent first, and
  # assert_gate_held/1 (which runs in the test process) turns it into a
  # failure.
  defp await_gate(gate, retries \\ 500)

  defp await_gate(gate, 0) do
    Agent.update(gate, &%{&1 | timed_out: true})
    flunk("timed out waiting for the gated indexer to be released; the gate was never opened")
  end

  defp await_gate(gate, retries) do
    if Agent.get(gate, & &1.open) do
      :ok
    else
      Process.sleep(10)
      await_gate(gate, retries - 1)
    end
  end

  # Must run in the test process; see await_gate/2 for why the handler cannot
  # report this itself.
  defp assert_gate_held(gate) do
    refute Agent.get(gate, & &1.timed_out),
           "the gated indexer stopped waiting and answered on its own, so the full " <>
             "search was never actually held behind the gate and this test proved nothing"
  end

  defp wait_until_search_finished(view, retries \\ 300)

  defp wait_until_search_finished(_view, 0) do
    flunk("timed out waiting for handle_search_async/2 to clear :searching")
  end

  defp wait_until_search_finished(view, retries) do
    if :sys.get_state(view.pid).socket.assigns.searching do
      Process.sleep(10)
      wait_until_search_finished(view, retries - 1)
    else
      :ok
    end
  end

  # See MydiaWeb.SearchLive.StreamingTest for the full rationale: the on_start
  # callback fires (and does a full-replace assign of indexer_progress)
  # before any HTTP request, so synthetic progress sent before it lands can be
  # silently wiped out by the real message arriving later.
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

  # From the moment the modal opens until the first indexer reports, the
  # display set is genuinely empty: the spinner must be up and the results
  # <ul> must not be rendered at all. Starting :results_empty? at false
  # inverts both gates -- `@searching && @results_empty?` suppresses the
  # spinner while `!@results_empty?` renders the list -- leaving the modal
  # body showing an empty list with no spinner and no message.
  #
  # The indexer is parked behind a Bypass that sleeps past this test's
  # lifetime, so neither on_indexer_result nor handle_search_async can land.
  test "a freshly opened manual search shows the spinner, not an empty list", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    view |> element("#manual-search-button") |> render_click()

    assert has_element?(view, "#manual-search-loading-state")
    refute has_element?(view, "#manual-search-results")
  end

  # Positive control for the refutation above: once an indexer reports
  # results, the list appears and the spinner goes away. Without this, a
  # passing refute could just mean "#manual-search-results" never renders
  # under any circumstance.
  test "the results list appears once an indexer reports", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "slow-indexer",
         indexer_id: indexer.id,
         status: :ok,
         results: [search_result("Dune.2024.2160p.UHD")],
         result_count: 1,
         duration_ms: 700,
         completed: 1,
         total: 1
       }}
    )

    render(view)

    assert has_element?(view, "#manual-search-results")
    refute has_element?(view, "#manual-search-loading-state")
  end

  # A result that reached the display set through on_indexer_result but is NOT
  # in the full search's aggregate return value is exactly what a
  # single-indexer retry produces: the retry runs under its own start_async
  # key ({:retry, id}), so its releases only ever arrive as progress messages
  # and never appear in the aggregate that handle_search_async/2 receives.
  # Injecting one directly models that precisely, and avoids clicking Retry
  # only to have the retry park on the same gated Bypass.
  test "a result contributed by a retry survives the full search completing", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    {_indexer, gate} = gated_indexer_fixture("gated-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2024.2160p.UHD")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "retried",
         indexer_id: "retried-id",
         status: :ok,
         results: [dune],
         result_count: 1,
         duration_ms: 120,
         completed: 1,
         total: 1
       }}
    )

    assert has_element?(view, "##{positioned_result_dom_id(dune)}"),
           "precondition failed: the retry's result never made it on screen"

    open_gate(gate)
    wait_until_search_finished(view)

    assert_gate_held(gate)
    assert has_element?(view, "##{positioned_result_dom_id(dune)}")
  end

  # Retrying ONE failed chip must not restart every other indexer. Both
  # indexers here are real, enabled DB-backed configs, which is what makes the
  # assertion discriminate: an unscoped retry re-runs search_all/2 over every
  # enabled indexer, so its on_start carries a :pending entry for
  # "healthy-indexer" too, and the Map.merge/2 in
  # handle_info({:indexer_search_started, ...}) flips that chip from :ok back
  # to :pending. Scoping the retry to [indexer_id] keeps the healthy chip
  # untouched (and stops multiplying load against indexers that ban on rate).
  test "retrying one indexer leaves the other indexers' chips untouched", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    flaky = pending_indexer_fixture("flaky-indexer")
    healthy = pending_indexer_fixture("healthy-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "healthy-indexer",
         indexer_id: healthy.id,
         status: :ok,
         results: [],
         result_count: 3,
         duration_ms: 500,
         completed: 1,
         total: 2
       }}
    )

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "flaky-indexer",
         indexer_id: flaky.id,
         status: :error,
         error: "Connection failed: :econnrefused",
         completed: 2,
         total: 2
       }}
    )

    assert has_element?(view, "#indexer-status-#{flaky.id} button")

    view
    |> element("#indexer-status-#{flaky.id} button")
    |> render_click()

    # The retry's own real on_start fires before any HTTP request (same
    # timing as the initial search's on_start above), so this outlasts it.
    # Both indexers' real on_indexer_result callbacks are still parked 3s
    # behind Bypass, well past this window.
    Process.sleep(300)

    progress = :sys.get_state(view.pid).socket.assigns.indexer_progress

    assert progress[flaky.id].status == :pending
    assert progress[healthy.id].status == :ok
    assert progress[healthy.id].result_count == 3
  end

  test "one indexer's results render while another is pending", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    view |> element("#manual-search-button") |> render_click()

    search_id = current_search_id(view)

    send(
      view.pid,
      {:indexer_search_started, search_id,
       [
         %IndexerProgress{indexer: "fast", indexer_id: "fast-id", status: :pending, total: 2},
         %IndexerProgress{indexer: "slow", indexer_id: "slow-id", status: :pending, total: 2}
       ]}
    )

    send(
      view.pid,
      {:indexer_progress, search_id,
       %IndexerProgress{
         indexer: "fast",
         indexer_id: "fast-id",
         status: :ok,
         results: [search_result("Dune.2021.2160p.UHD")],
         result_count: 1,
         duration_ms: 700,
         completed: 1,
         total: 2
       }}
    )

    html = render(view)

    assert html =~ "Dune.2021.2160p.UHD"
    assert has_element?(view, "#indexer-status-fast-id")
    assert has_element?(view, "#indexer-status-slow-id")
  end

  # The stale result's title genuinely matches the search query ("Dune 2024",
  # since media_item_fixture/1 defaults year to 2024) rather than something
  # unrelated. If it didn't, ReleaseRanker's title-relevance filter (when a
  # quality profile is present) could explain the result's absence just as
  # well as the search_id guard, making the assertion below ambiguous about
  # which mechanism is actually responsible.
  defp stale_progress(indexer_id, title) do
    %IndexerProgress{
      indexer: "old",
      indexer_id: indexer_id,
      status: :ok,
      results: [search_result(title)],
      result_count: 1,
      duration_ms: 100,
      completed: 1,
      total: 1
    }
  end

  test "stale progress is ignored", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()

    send(
      view.pid,
      {:indexer_progress, current_search_id(view) - 1,
       stale_progress("old-id", "Dune.2024.2160p.UHD")}
    )

    refute render(view) =~ "Dune.2024.2160p.UHD"
  end

  # Positive control for the test above: the exact same message, differing
  # only in carrying the CURRENT search_id, must surface the result. Without
  # this, a passing refute in the stale test could just as easily mean the
  # element selector or title never renders under any circumstance, rather
  # than proving the search_id guard is what's filtering it out.
  test "a matching (non-stale) search_id does surface the same content", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       stale_progress("old-id", "Dune.2024.2160p.UHD")}
    )

    html = render(view)

    assert html =~ "Dune.2024.2160p.UHD"
    assert has_element?(view, "#indexer-status-old-id")
  end

  # A single indexer cannot prove handle_info({:indexer_search_started, ...})
  # MERGES rather than REPLACES: with one entry in indexer_progress, "wiped
  # the map down to just this one pending entry" and "correctly updated this
  # one entry to pending" are indistinguishable. A second entry ("succeeded-
  # id") makes the two hypotheses diverge. It is deliberately NOT backed by a
  # real indexer_config (same pattern as the "old"/"old-id" entries used
  # elsewhere in this file), so it can never appear in any real on_start's
  # pending list, exactly mirroring an indexer that already finished and
  # should NOT be touched. A REPLACE-based handler would wipe "succeeded-id"
  # out of indexer_progress the moment the retry's real on_start message
  # lands; a MERGE-based one preserves it.
  #
  # The companion test "retrying one indexer leaves the other indexers' chips
  # untouched" covers the other half of the same pairing: that the retry's
  # on_start is SCOPED to the retried indexer, using two real DB-backed
  # configs so an unscoped retry would be visible.
  test "retrying a failed indexer marks it pending again without wiping other indexers", %{
    conn: conn
  } do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("flaky-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
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
    # timing as the initial search's on_start above), so this short wait
    # reliably outlasts it before we inspect final state.
    Process.sleep(200)

    progress = :sys.get_state(view.pid).socket.assigns.indexer_progress

    assert progress[indexer.id].status == :pending
    assert progress["succeeded-id"].status == :ok
    assert progress["succeeded-id"].result_count == 3
  end

  # Before this task, no handle_event("retry_indexer", ...) clause existed on
  # this LiveView, so clicking Retry raised a FunctionClauseError and crashed
  # the process. render_click/1 re-raises that crash in the test process, so
  # simply completing the click and then successfully rendering the view
  # again is direct proof the crash is gone.
  test "retrying a failed indexer does not crash the LiveView", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("flaky-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
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

  # Retry starts a real indexer search, exactly like the three other entry
  # points on this LiveView (manual search, auto search, grab), all of which
  # sit behind Authorization.authorize_manage_downloads/1. It shipped without
  # that check, so a role that cannot manage downloads could still drive
  # indexer traffic by pushing the event over the socket.
  #
  # The event is pushed directly rather than clicked: a guest never sees the
  # Retry button (they cannot open the modal at all), and pushing over the
  # socket is precisely the attack the guard has to stop.
  #
  # The positive control is the pair of tests above, which push the same event
  # as the default "user" role from setup and observe the chip flip to
  # :pending. A guard that rejected everyone would fail those.
  test "a role that cannot manage downloads cannot retry an indexer" do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    {conn, _guest} = register_and_log_in_user(build_conn(), %{role: "guest"})

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    failed = %IndexerProgress{
      indexer: "flaky-indexer",
      indexer_id: "flaky-id",
      status: :error,
      error: "Connection failed: :econnrefused",
      completed: 1,
      total: 1
    }

    # search_id is still 0 for a user who never started a search, so this
    # passes the stale-guard in handle_info({:indexer_progress, ...}).
    send(view.pid, {:indexer_progress, current_search_id(view), failed})
    render(view)

    render_click(view, "retry_indexer", %{"id" => "flaky-id"})

    state = :sys.get_state(view.pid).socket.assigns

    assert state.indexer_progress["flaky-id"].status == :error,
           "the retry ran despite the user lacking manage-downloads permission"

    assert state.flash["error"] =~ "permission"
  end

  # handle_retry_indexer/2 sets the chip to :pending before starting the task.
  # If that task dies or errors before any progress message lands, nothing else
  # ever clears :pending: the chip spins forever and the Retry button is gone,
  # because it only renders for :error/:timeout. These drive handle_async/3
  # directly because the failure modes (a crashed task, a non-:ok return from
  # search_all/2) cannot be provoked through a live indexer.
  describe "handle_async({:retry, id}, ...)" do
    defp retry_socket(indexer_progress) do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, indexer_progress: indexer_progress}
      }
    end

    defp pending_retry_progress do
      %{
        "flaky-id" => %IndexerProgress{
          indexer: "flaky-indexer",
          indexer_id: "flaky-id",
          status: :pending,
          result_count: nil,
          duration_ms: nil,
          total: 1
        }
      }
    end

    test "a crashed retry leaves the indexer actionable, not pending forever" do
      {:noreply, socket} =
        MydiaWeb.MediaLive.Show.handle_async(
          {:retry, "flaky-id"},
          {:exit, :killed},
          retry_socket(pending_retry_progress())
        )

      entry = socket.assigns.indexer_progress["flaky-id"]

      assert entry.status == :error
      assert is_binary(entry.error) and entry.error != ""
      assert entry.result_count == nil
      assert entry.duration_ms == nil
    end

    test "a retry that returns an error leaves the indexer actionable" do
      {:noreply, socket} =
        MydiaWeb.MediaLive.Show.handle_async(
          {:retry, "flaky-id"},
          {:ok, {:error, :boom}},
          retry_socket(pending_retry_progress())
        )

      assert socket.assigns.indexer_progress["flaky-id"].status == :error
    end

    # The success case must stay a no-op: the retry's releases already arrived
    # as progress messages, and its batched aggregate covers only the retried
    # indexer, so applying it would clobber every other indexer's chip.
    test "a successful retry does not touch indexer_progress" do
      progress = pending_retry_progress()

      {:noreply, socket} =
        MydiaWeb.MediaLive.Show.handle_async(
          {:retry, "flaky-id"},
          {:ok, {:ok, [], []}},
          retry_socket(progress)
        )

      assert socket.assigns.indexer_progress == progress
    end

    test "an unknown indexer id is a clean no-op rather than an insert" do
      progress = pending_retry_progress()

      {:noreply, socket} =
        MydiaWeb.MediaLive.Show.handle_async(
          {:retry, "never-seen-id"},
          {:exit, :killed},
          retry_socket(progress)
        )

      assert socket.assigns.indexer_progress == progress
    end
  end

  # Per-row grab flags are written into the stream by mark_result/3 and live
  # nowhere else, while every progress message rebuilds that stream with
  # reset: true. Before results streamed in, rows were only clickable once the
  # search had finished, so no reset could follow a grab. Now a user can grab
  # while a slow indexer is still running and watch the badge disappear when
  # the next indexer reports.
  #
  # The second progress message deliberately carries NO results: an unchanged
  # pool keeps the row's rank (and therefore its positioned DOM id) fixed, so
  # a failure can only mean the flag was dropped, never that the row moved.
  test "a grab badge survives the next indexer reporting", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2024.2160p.UHD")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "slow-indexer",
         indexer_id: indexer.id,
         status: :ok,
         results: [dune],
         result_count: 1,
         duration_ms: 700,
         completed: 1,
         total: 2
       }}
    )

    render(view)

    # The same message Downloads.Grabber broadcasts on the "downloads" topic
    # when a grab lands, which is what flips the row to "Grabbed".
    send(view.pid, {:grab_completed, %{download_url: dune.download_url}})
    render(view)

    row = "##{positioned_result_dom_id(dune)}"

    assert has_element?(view, "#{row} .btn-success"),
           "precondition failed: the grabbed badge never rendered"

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "other-indexer",
         indexer_id: "other-id",
         status: :ok,
         results: [],
         result_count: 0,
         duration_ms: 90,
         completed: 2,
         total: 2
       }}
    )

    render(view)

    assert has_element?(view, "#{row} .btn-success"),
           "the grabbed badge was erased by the next indexer's progress message"
  end

  # The results list renders as soon as the first indexer reports, but the
  # filters bar above it used to stay gated on `!@searching`, so a user could
  # see streamed results and not be able to filter or re-sort them until the
  # slowest indexer settled, which can be the full 120s deadline.
  test "filter and sort controls are available while a slow indexer runs", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    # Nothing has arrived yet, so there is nothing to filter and the bar must
    # stay hidden. Without this the assertion below could pass on a bar that
    # simply always renders.
    refute has_element?(view, "#close-after-grab-toggle")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "slow-indexer",
         indexer_id: indexer.id,
         status: :ok,
         results: [search_result("Dune.2024.2160p.UHD")],
         result_count: 1,
         duration_ms: 700,
         completed: 1,
         total: 2
       }}
    )

    render(view)

    assert :sys.get_state(view.pid).socket.assigns.searching,
           "precondition failed: the search already ended, so this proves nothing"

    assert has_element?(view, ~s(#manual-search-modal form[phx-change="filter_search"]))
    assert has_element?(view, ~s(#manual-search-modal form[phx-change="sort_search"]))
    assert has_element?(view, "#close-after-grab-toggle")
  end

  # Two things at once: the filter handler re-filters the accumulated set
  # correctly mid-search, and filtering down to nothing does NOT take the
  # controls away with it. That second half is why the bar is gated on the
  # pre-filter pool rather than on `!@results_empty?` like the results list:
  # test fixtures carry no parsed quality, so a resolution filter matches
  # nothing, and gating on the post-filter set would strand the user with no
  # way to undo the filter they just applied.
  test "a filter applied mid-search re-filters without stranding the user", %{conn: conn} do
    media_item = media_item_fixture(%{title: "Dune", type: "movie"})
    indexer = pending_indexer_fixture("slow-indexer")

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")
    view |> element("#manual-search-button") |> render_click()
    wait_for_indexer_progress(view)

    dune = search_result("Dune.2024.2160p.UHD")

    send(
      view.pid,
      {:indexer_progress, current_search_id(view),
       %IndexerProgress{
         indexer: "slow-indexer",
         indexer_id: indexer.id,
         status: :ok,
         results: [dune],
         result_count: 1,
         duration_ms: 700,
         completed: 1,
         total: 2
       }}
    )

    render(view)
    assert has_element?(view, "##{positioned_result_dom_id(dune)}")

    view
    |> element(~s(#manual-search-modal form[phx-change="filter_search"]))
    |> render_change(%{"quality" => "2160p", "min_seeders" => "0"})

    refute has_element?(view, "##{positioned_result_dom_id(dune)}")

    assert has_element?(view, ~s(#manual-search-modal form[phx-change="filter_search"])),
           "the filter that matched nothing also removed the controls needed to undo it"

    view
    |> element(~s(#manual-search-modal form[phx-change="filter_search"]))
    |> render_change(%{"quality" => "", "min_seeders" => "0"})

    assert has_element?(view, "##{positioned_result_dom_id(dune)}")
  end
end
