defmodule MydiaWeb.SearchLive.DownloadModalTest do
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
  alias MydiaWeb.Live.SearchResultRef

  @unparseable "invented readme"

  setup %{conn: conn} do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    movies = library_path_fixture(%{type: "movies", name: "Invented Movies"})
    series = library_path_fixture(%{type: "series", name: "Invented Series"})

    %{conn: log_in_user(conn, admin_user_fixture()), movies: movies, series: series}
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

  # Same technique as TypeFilterTest: an indexer that never answers keeps the
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
    search_id = :sys.get_state(view.pid).socket.assigns.search_id

    send(
      view.pid,
      {:indexer_progress, search_id,
       %IndexerProgress{
         indexer: "pending",
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
    view
  end

  test "rows and the detail modal never carry a passkey", %{conn: conn} do
    r = %{
      result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
      | download_url:
          "https://tracker.example.test/dl/42?passkey=feedface0123&torrent_pass=cafe99",
        indexer: "Velvet Lantern"
    }

    view = page_with(conn, [r])
    refute render(view) =~ "feedface0123"

    view |> element(~s(td[phx-click="show_detail"])) |> render_click()
    html = render(view)

    assert has_element?(
             view,
             ~s(button[phx-click="show_download_modal"][phx-value-ref="#{SearchResultRef.ref(r)}"])
           )

    refute html =~ "passkey="
    refute html =~ "torrent_pass="

    view |> element(~s(.modal button[phx-click="show_download_modal"])) |> render_click()
    assert has_element?(view, "#download-modal")
  end

  test "opens the modal even when the category is known", %{conn: conn, movies: movies} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    assert has_element?(view, "#download-modal #download-config-form")

    assert has_element?(
             view,
             ~s(#download-config-form input[name=media_type][value=movie][checked])
           )

    assert has_element?(
             view,
             ~s(select[name="config[library_path_id]"] option[value="#{movies.id}"])
           )
  end

  test "lists only the chosen type's libraries and swaps on type change",
       %{conn: conn, movies: movies, series: series} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", nil)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    refute has_element?(view, ~s(option[value="#{series.id}"]))

    view
    |> form("#download-config-form", %{"media_type" => "tv_show"})
    |> render_change()

    assert has_element?(
             view,
             ~s(select[name="config[library_path_id]"] option[value="#{series.id}"])
           )

    refute has_element?(view, ~s(option[value="#{movies.id}"]))
    assert has_element?(view, ~s(select[name="config[season_monitoring]"]))
  end

  test "an unclassifiable release opens with no type chosen", %{conn: conn} do
    r = result(@unparseable, nil)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    assert has_element?(view, "#download-config-form")
    refute has_element?(view, ~s(#download-config-form input[name=media_type][checked]))
    refute has_element?(view, ~s(select[name="config[library_path_id]"]))
    assert has_element?(view, "#download-config-form button[type=submit][disabled]")
  end

  test "the search-on-add toggle is not offered", %{conn: conn} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    assert has_element?(view, "#download-modal")
    refute has_element?(view, ~s(input[name="config[search_on_add]"]))
  end

  test "closing clears the modal", %{conn: conn} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})
    assert has_element?(view, "#download-modal")
    render_click(view, "close_download_modal", %{})

    refute has_element?(view, "#download-modal")
  end

  test "a detected type with no library is not swapped for the other type",
       %{conn: conn, movies: movies} do
    Mydia.Settings.delete_library_path(movies)
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    assert has_element?(view, "#download-modal")
    refute has_element?(view, ~s(#download-config-form input[name=media_type][checked]))
    refute has_element?(view, ~s(select[name="config[library_path_id]"]))
    assert has_element?(view, "#download-config-form button[type=submit][disabled]")
  end
end
