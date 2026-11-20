defmodule MydiaWeb.MediaLive.Show.DownloadCancelTest do
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Downloads.Download
  alias Mydia.Repo

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  test "cancelling requests the removal and leaves the client call to the job", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Bay", year: 2021})
    download = download_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})
    render_click(view, "cancel_download", %{})

    row = Repo.get!(Download, download.id)
    assert row.removal_kind == "cancel"
    refute row.removal_delete_files
    assert_enqueued(worker: Mydia.Jobs.RemoveDownload, args: %{"download_id" => download.id})
  end

  # Issue #1436: partial files left behind blocked a later grab of the release.
  test "the cancel dialog deletes the partial files by default", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Reach", year: 2021})
    download = download_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})

    assert has_element?(view, "#download-cancel-delete-files[checked]")

    view |> element("#download-cancel-form") |> render_submit(%{"delete_files" => "true"})

    row = Repo.get!(Download, download.id)
    assert row.removal_kind == "cancel"
    assert row.removal_delete_files
  end

  test "the cancel dialog can keep the partial files", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Ford", year: 2021})
    download = download_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})
    view |> element("#download-cancel-form") |> render_submit(%{"delete_files" => "false"})

    refute Repo.get!(Download, download.id).removal_delete_files
  end

  test "an account that cannot manage downloads cannot cancel one", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Lantern Weir", year: 2021})
    download = download_fixture(%{media_item_id: movie.id})
    conn = log_in_user(conn, user_fixture(%{role: "readonly"}))

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})

    assert render_click(view, "cancel_download", %{"delete_files" => "true"}) =~
             "You do not have permission to manage downloads"

    refute Repo.get!(Download, download.id).removal_requested_at
    refute_enqueued(worker: Mydia.Jobs.RemoveDownload)
  end

  test "the cancel dialog warns of a hit-and-run before the tracker's goal is met, and still cancels",
       %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Copper Estuary", year: 2024})

    guarded =
      download_fixture(%{
        media_item_id: movie.id,
        indexer: "Velvet Lantern",
        metadata: %{"tracker_terms" => %{"private" => true, "minimum_ratio" => 1.0}}
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "show_download_cancel_confirm", %{"download-id" => guarded.id})

    assert has_element?(
             view,
             "#seeding-removal-warning",
             "Velvet Lantern requires a ratio of 1.0"
           )

    assert has_element?(view, "#seeding-removal-warning", "hit-and-run")

    render_click(view, "cancel_download", %{})
    assert Repo.get!(Download, guarded.id).removal_kind == "cancel"
  end

  test "the cancel dialog has no seeding warning without tracker terms", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Quiet Harbor", year: 2024})
    download = download_fixture(%{media_item_id: movie.id})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})

    refute has_element?(view, "#seeding-removal-warning")
  end

  test "cancelling a stalled download says the release is blocked", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Stalled Beacon", year: 2022})

    download =
      download_fixture(%{
        media_item_id: movie.id,
        indexer: "fictional-indexer",
        metadata: %{"guid" => "media-page-stalled-guid"},
        stalled_since: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})
    render_click(view, "cancel_download", %{})

    assert has_element?(view, "#flash-info", "grab it again")

    assert Mydia.Downloads.Blacklists.blacklisted?(
             "fictional-indexer",
             "media-page-stalled-guid"
           )
  end

  test "cancelling a stalled download with no blacklist key does not promise a ban", %{
    conn: conn
  } do
    movie = media_item_fixture(%{type: "movie", title: "Fictional Adopted Lantern", year: 2023})

    download =
      download_fixture(%{
        media_item_id: movie.id,
        indexer: nil,
        metadata: %{},
        stalled_since: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "show_download_cancel_confirm", %{"download-id" => download.id})
    render_click(view, "cancel_download", %{})

    assert has_element?(view, "#flash-info", "Cancelling the download")
    refute has_element?(view, "#flash-info", "grab it again")
  end
end
