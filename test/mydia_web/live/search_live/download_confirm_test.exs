defmodule MydiaWeb.SearchLive.DownloadConfirmTest.TwoHitProvider do
  @moduledoc false
  # The stub catalog has one movie. This serves it plus a second hit, so the
  # add reaches disambiguation. Defined here rather than borrowed from
  # RestrictedAutoMatchTest so this file also runs on its own.

  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.MetadataStubProvider

  def search(config, query, opts) do
    with {:ok, [movie]} <- MetadataStubProvider.search(config, query, opts) do
      other = %SearchResult{
        movie
        | provider_id: "8800124",
          id: 8_800_124,
          title: "Other Invented Movie",
          original_title: "Other Invented Movie"
      }

      {:ok, [movie, other]}
    end
  end

  defdelegate fetch_by_ref(config, ref, opts), to: MetadataStubProvider
end

defmodule MydiaWeb.SearchLive.DownloadConfirmTest.BlockingProvider do
  @moduledoc false
  # Holds the add in flight: search announces itself to the test process and
  # waits for a release message, so a test can confirm a second row while the
  # first is still being added.

  alias Mydia.MetadataStubProvider

  def search(config, query, opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), {:add_blocked, self()})

    receive do
      :release -> MetadataStubProvider.search(config, query, opts)
    after
      10_000 -> {:error, :blocked_too_long}
    end
  end

  defdelegate fetch_by_ref(config, ref, opts), to: MetadataStubProvider
end

defmodule MydiaWeb.SearchLive.DownloadConfirmTest.BlockingFetchProvider do
  @moduledoc false
  # Two hits so the add reaches disambiguation, then the metadata fetch of the
  # picked match holds the finalize task in flight until the test releases it.

  alias Mydia.MetadataStubProvider
  alias MydiaWeb.SearchLive.DownloadConfirmTest.TwoHitProvider

  defdelegate search(config, query, opts), to: TwoHitProvider

  def fetch_by_ref(config, ref, opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), {:fetch_blocked, self()})

    receive do
      :release -> MetadataStubProvider.fetch_by_ref(config, ref, opts)
    after
      10_000 -> {:error, :blocked_too_long}
    end
  end
end

defmodule MydiaWeb.SearchLive.DownloadConfirmTest do
  # The metadata stub registry is global.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataStub
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Media.AddDefaults
  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Provider.Registry
  alias Mydia.Repo
  alias Mydia.Settings
  alias MydiaWeb.Live.SearchResultRef
  alias MydiaWeb.SearchLive.ReleaseAdd
  alias MydiaWeb.SearchLive.DownloadConfirmTest.BlockingFetchProvider
  alias MydiaWeb.SearchLive.DownloadConfirmTest.BlockingProvider
  alias MydiaWeb.SearchLive.DownloadConfirmTest.TwoHitProvider

  setup :setup_metadata_stub

  setup %{conn: conn} do
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    movies = library_path_fixture(%{type: "movies", name: "Invented Movies"})
    series = library_path_fixture(%{type: "series", name: "Invented Series"})

    %{conn: log_in_user(conn, admin_user_fixture()), movies: movies, series: series}
  end

  # Same helpers as DownloadModalTest. Kept local rather than shared so each
  # file reads on its own.
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

  defp open_and_submit(view, r, params) do
    render_click(view, "show_download_modal", %{"ref" => SearchResultRef.ref(r)})

    view
    |> form("#download-config-form", Map.take(params, ["media_type"]))
    |> render_change()

    # element/2, not form/3: form/3 validates values against the rendered
    # options, and the refusal test deliberately sends one that is not there.
    view
    |> element("#download-config-form")
    |> render_submit(params)
  end

  test "a movie-looking release confirmed as TV lands as a series in the chosen library",
       %{conn: conn, series: series} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    open_and_submit(view, r, %{
      "media_type" => "tv_show",
      "config" => %{
        "library_path_id" => series.id,
        "monitored" => "true",
        "season_monitoring" => "none"
      }
    })

    refute has_element?(view, "#download-modal")
    render_async(view, 5_000)

    item = Repo.one!(MediaItem)
    assert item.type == "tv_show"
    assert item.library_path_id == series.id
  end

  test "a library of the wrong type is refused and nothing is created",
       %{conn: conn, series: series} do
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    html =
      open_and_submit(view, r, %{
        "media_type" => "movie",
        "config" => %{"library_path_id" => series.id}
      })

    assert html =~ "That library is no longer available"
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  test "multiple matches open with no download modal behind them",
       %{conn: conn, movies: movies} do
    Registry.register(:metadata_relay, TwoHitProvider)
    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    open_and_submit(view, r, %{
      "media_type" => "movie",
      "config" => %{"library_path_id" => movies.id}
    })

    render_async(view, 5_000)

    assert has_element?(view, "#disambiguation-dialog")
    refute has_element?(view, "#download-modal")
  end

  test "confirming a second row while one add is in flight is refused",
       %{conn: conn, movies: movies} do
    :persistent_term.put({BlockingProvider, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({BlockingProvider, :test_pid}) end)
    Registry.register(:metadata_relay, BlockingProvider)

    a = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    b = result("Invented.Sequel.2022.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [a, b])
    params = %{"media_type" => "movie", "config" => %{"library_path_id" => movies.id}}

    open_and_submit(view, a, params)
    assert_receive {:add_blocked, task_pid}, 5_000

    html = open_and_submit(view, b, params)
    assert html =~ "Another release is still being added"
    refute has_element?(view, "#download-modal")
    refute has_element?(view, ~s(button[phx-value-ref="#{SearchResultRef.ref(b)}"][disabled]))

    send(task_pid, :release)
    render_async(view, 5_000)

    assert Repo.aggregate(MediaItem, :count) == 1
    assert Repo.one!(MediaItem).library_path_id == movies.id
    assert :sys.get_state(view.pid).socket.assigns.downloading_urls == MapSet.new()
  end

  test "closing the disambiguation modal cancels an in-flight finalize",
       %{conn: conn, movies: movies} do
    :persistent_term.put({BlockingFetchProvider, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({BlockingFetchProvider, :test_pid}) end)
    Registry.register(:metadata_relay, BlockingFetchProvider)

    r = result("Invented.Feature.2021.1080p.BluRay.x264-GRP", 2040)
    view = page_with(conn, [r])

    open_and_submit(view, r, %{
      "media_type" => "movie",
      "config" => %{"library_path_id" => movies.id}
    })

    render_async(view, 5_000)
    assert has_element?(view, "#disambiguation-dialog")

    [match | _] = :sys.get_state(view.pid).socket.assigns.metadata_matches
    render_click(view, "select_metadata_match", %{"match_id" => to_string(match.provider_id)})
    assert_receive {:fetch_blocked, task_pid}, 5_000

    render_click(view, "close_disambiguation_modal", %{})
    send(task_pid, :release)
    html = render_async(view, 5_000)

    refute html =~ "Failed to add to library"
    assert Repo.aggregate(MediaItem, :count) == 0
    assert :sys.get_state(view.pid).socket.assigns.downloading_urls == MapSet.new()
  end

  test "the add_to_library event no longer exists", %{conn: conn} do
    view = page_with(conn, [])

    # The page has no clause for the event, so the LiveView process crashes;
    # trap the linked exit rather than let it take the test down.
    Process.flag(:trap_exit, true)
    ref = Process.monitor(view.pid)
    catch_exit(render_click(view, "add_to_library", %{"title" => "Invented.Feature.2021"}))

    # The reason the proxy reports varies with timing, so assert only that the
    # view died abnormally and created nothing.
    assert_receive {:DOWN, ^ref, :process, _pid, reason}
    refute reason == :normal
    assert Repo.aggregate(MediaItem, :count) == 0
  end

  describe "download_opts/3" do
    test "a newly created item downloads into the chosen library" do
      defaults = %AddDefaults{
        library_path_id: "lib-1",
        monitored: true,
        season_monitoring: "all",
        search_on_add: false
      }

      assert ReleaseAdd.download_opts("item-1", :created, defaults) ==
               [media_item_id: "item-1", library_path_id: "lib-1"]
    end

    test "an existing item keeps its own library" do
      defaults = %AddDefaults{
        library_path_id: "lib-1",
        monitored: true,
        season_monitoring: "all",
        search_on_add: false
      }

      assert ReleaseAdd.download_opts("item-1", :existing, defaults) == [media_item_id: "item-1"]
    end
  end
end
