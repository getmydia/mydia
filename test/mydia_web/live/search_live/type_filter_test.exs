defmodule MydiaWeb.SearchLive.TypeFilterTest do
  # async: false: connected LiveView tests deadlock under the Postgres
  # sandbox when run concurrently, and indexer configs are global.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Settings

  @unparseable "invented readme"

  setup %{conn: conn} do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp result(title, category) do
    %SearchResult{
      title: title,
      size: 2_000_000_000,
      seeders: 10,
      leechers: 1,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "Public",
      category: category
    }
  end

  defp dom_id(r), do: "search-result-#{:erlang.phash2({r.download_url, r.indexer})}"

  # Same technique as StreamingTest: an indexer that never answers keeps the
  # real search open, and synthetic progress delivers the results.
  defp pending_indexer do
    bypass = Bypass.open()
    Mydia.IndexerMock.stub_prowlarr_indexer_status(bypass)

    Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
      Bypass.pass(bypass)
      Process.sleep(3_000)
      Plug.Conn.resp(conn, 200, "[]")
    end)

    indexer_config_fixture(%{
      name: "pending",
      type: :prowlarr,
      base_url: "http://localhost:#{bypass.port}"
    })
  end

  defp wait_for_progress(view, retries \\ 50)
  defp wait_for_progress(_view, 0), do: flunk("search never started")

  defp wait_for_progress(view, retries) do
    if :sys.get_state(view.pid).socket.assigns.indexer_progress == %{} do
      Process.sleep(10)
      wait_for_progress(view, retries - 1)
    end
  end

  defp page_with(conn, results) do
    indexer = pending_indexer()
    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=invented")
    wait_for_progress(view)

    send_progress(view, indexer, results)

    render(view)
    view
  end

  defp send_progress(view, indexer, results) do
    search_id = :sys.get_state(view.pid).socket.assigns.search_id

    send(
      view.pid,
      {:indexer_progress, search_id,
       %IndexerProgress{
         indexer: indexer.name,
         indexer_id: indexer.id,
         status: :ok,
         results: results,
         result_count: length(results),
         duration_ms: 10,
         completed: 1,
         total: 1
       }}
    )

    render(view)
  end

  defp filter(view, type) do
    view
    |> form("#search-filter-form", %{"library_type" => type})
    |> render_change()
  end

  test "uncategorized releases are filtered by their parsed type", %{conn: conn} do
    episode = result("Invented.Show.S01E02.1080p.WEB-DL.x264-GRP", nil)
    feature = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", nil)
    unknown = result(@unparseable, nil)

    view = page_with(conn, [episode, feature, unknown])

    filter(view, "series")
    assert has_element?(view, "##{dom_id(episode)}")
    refute has_element?(view, "##{dom_id(feature)}")
    refute has_element?(view, "##{dom_id(unknown)}")

    filter(view, "movies")
    assert has_element?(view, "##{dom_id(feature)}")
    refute has_element?(view, "##{dom_id(episode)}")

    filter(view, "all")
    assert has_element?(view, "##{dom_id(unknown)}")
  end

  test "a title-based guess is marked on the badge", %{conn: conn} do
    episode = result("Invented.Show.S01E02.1080p.WEB-DL.x264-GRP", nil)
    categorized = result("Invented.Show.S01E03.1080p.WEB-DL.x264-GRP", 5040)

    view = page_with(conn, [episode, categorized])

    assert has_element?(view, "##{dom_id(episode)} [data-type-source=title]")
    assert has_element?(view, "##{dom_id(categorized)} [data-type-source=category]")
  end

  test "a later indexer's category reclassifies a release already cached", %{conn: conn} do
    uncategorized = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", nil)
    categorized = %{uncategorized | indexer: "Other", category: 5040}

    view = page_with(conn, [uncategorized])

    other =
      indexer_config_fixture(%{name: "other", type: :prowlarr, base_url: "http://localhost:1"})

    send_progress(view, other, [categorized])

    filter(view, "series")
    assert has_element?(view, "##{dom_id(categorized)}")
    assert has_element?(view, "##{dom_id(categorized)} [data-type-source=category]")
  end
end
