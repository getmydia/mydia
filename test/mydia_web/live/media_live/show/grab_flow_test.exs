defmodule MydiaWeb.MediaLive.Show.GrabFlowTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Repo
  alias MydiaWeb.Live.SearchResultRef

  # A private tracker's download link: the passkey must never reach the page.
  @release %SearchResult{
    title: "Some.Movie.2020.1080p",
    download_url: "https://tracker.example.test/dl/42?passkey=feedface0123&torrent_pass=cafe99",
    # Carries the passkey too, so the page assertions also cover the guid.
    guid: "https://tracker.example.test/details/42?passkey=feedface0123",
    indexer: "Velvet Lantern",
    size: 1000,
    seeders: 5,
    leechers: 1,
    download_protocol: :torrent,
    terms: %Mydia.Indexers.Structs.TrackerTerms{private?: true, minimum_ratio: 1.0}
  }

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)
    movie = media_item_fixture(%{type: "movie", title: "Some Movie", year: 2020})
    Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    %{conn: conn, movie: movie, admin: admin}
  end

  # Opens the dialog (no indexers configured, so the search itself finds
  # nothing) and feeds it @release the way an indexer's progress message would.
  defp open_with_release(view) do
    render_click(view, "manual_search", %{})
    search_id = :sys.get_state(view.pid).socket.assigns.search_id

    send(
      view.pid,
      {:indexer_progress, search_id,
       %IndexerProgress{
         indexer: "Velvet Lantern",
         indexer_id: "velvet",
         status: :ok,
         results: [@release],
         result_count: 1,
         duration_ms: 10,
         completed: 1,
         total: 1
       }}
    )

    render(view)
  end

  test "the dialog references the release without its passkey", %{conn: conn, movie: movie} do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    html = open_with_release(view)

    assert has_element?(
             view,
             ~s(button[phx-click="download_from_search"][phx-value-ref="#{SearchResultRef.ref(@release)}"])
           )

    refute html =~ "passkey="
    refute html =~ "torrent_pass="
    refute html =~ "feedface0123"
  end

  test "download click inserts the record and returns without waiting", %{
    conn: conn,
    movie: movie
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    open_with_release(view)

    view |> element(~s(button[phx-click="download_from_search"])) |> render_click()

    # The record exists immediately after the click returns, built from the
    # server-side result rather than anything the page sent.
    download = Repo.get_by(Download, title: "Some.Movie.2020.1080p")
    assert download
    assert download.media_item_id == movie.id
    assert download.download_url == @release.download_url
    assert download.indexer == "Velvet Lantern"
    # The result's own fields survive, which a row-built result never carried.
    assert download.metadata["guid"] == @release.guid
    assert download.metadata["download_protocol"] in ["torrent", :torrent]

    assert %{private?: true, minimum_ratio: 1.0} =
             Mydia.Indexers.Structs.TrackerTerms.from_map(download.metadata["tracker_terms"])

    # The background task fails (no download clients configured) and says so.
    # Pinned: an earlier test's grab task can still broadcast on the topic.
    download_id = download.id
    assert_receive {:grab_failed, %{download_id: ^download_id}}, 2_000

    # The modal stays open by default, and the row shows the failure.
    render_async(view)
    assert has_element?(view, "#manual-search-modal")
    assert has_element?(view, ~s(button.btn-error[phx-click="download_from_search"]))
  end

  test "a tracker at its daily grab cap says so on the row", %{conn: conn, movie: movie} do
    {:ok, _} =
      Mydia.Settings.TrackerRuleConfigs.create(%{tracker: "velvet lantern", grab_limit: 1})

    Mydia.DownloadsFixtures.download_fixture(%{indexer: "Velvet Lantern"})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    open_with_release(view)

    assert has_element?(view, "[id$='-limit']", "daily grab limit reached (1/1)")
    # Manual search still lets the user grab it.
    assert has_element?(view, ~s(button[phx-click="download_from_search"]))
  end

  test "an unknown reference grabs nothing and says so", %{conn: conn, movie: movie} do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    open_with_release(view)

    html = render_click(view, "download_from_search", %{"ref" => "not-a-ref"})

    assert html =~ "no longer in the results"
    refute Repo.get_by(Download, title: "Some.Movie.2020.1080p")
  end

  test "toggle persists the close-after-grab preference", %{
    conn: conn,
    movie: movie,
    admin: admin
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "manual_search", %{})
    render_async(view)

    assert has_element?(view, "#close-after-grab-toggle")
    render_click(view, "toggle_close_after_grab", %{})

    pref = Mydia.Accounts.get_user_preference!(admin)
    assert Mydia.Accounts.UserPreference.close_manual_search_after_grab?(pref)
  end

  test "grab closes the modal when the preference is enabled", %{
    conn: conn,
    movie: movie,
    admin: admin
  } do
    pref = Mydia.Accounts.get_user_preference!(admin)

    {:ok, _} =
      Mydia.Accounts.update_preference(pref, %{"close_manual_search_after_grab" => true})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    open_with_release(view)
    assert has_element?(view, "#manual-search-modal")

    view |> element(~s(button[phx-click="download_from_search"])) |> render_click()

    refute has_element?(view, "#manual-search-modal")
  end
end
