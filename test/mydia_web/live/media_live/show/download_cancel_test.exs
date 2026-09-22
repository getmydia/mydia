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
end
