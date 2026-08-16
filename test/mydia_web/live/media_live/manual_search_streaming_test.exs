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

  test "retrying a failed indexer marks it pending again", %{conn: conn} do
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

    assert has_element?(view, "#indexer-status-#{indexer.id} button")

    view
    |> element("#indexer-status-#{indexer.id} button")
    |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.indexer_progress[indexer.id].status ==
             :pending
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
end
