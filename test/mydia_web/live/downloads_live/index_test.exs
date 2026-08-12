defmodule MydiaWeb.DownloadsLive.IndexTest do
  # Not async: a connected LiveView mount runs in a separate process from the
  # test. Under PostgreSQL with async: true the sandbox is non-shared, so that
  # process can't see the rows this test inserts, the download list renders
  # empty, and the sort control (gated on rows existing) never appears. Shared
  # mode (the non-async default) makes the inserted rows visible to the mount.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Library

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  # No download client is configured in these tests, so list_downloads_with_status
  # returns every download regardless of tab filter. That's fine here — we assert
  # on sort ordering and control state, not on tab filtering or live client fields.

  defp completed_download(title, attrs \\ %{}) do
    media_item = media_item_fixture(%{title: title})

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  # Returns the given substrings ordered by where they appear in the html.
  defp order_in(html, substrings) do
    substrings
    |> Enum.map(fn s ->
      {pos, _len} = :binary.match(html, s)
      {s, pos}
    end)
    |> Enum.sort_by(fn {_s, pos} -> pos end)
    |> Enum.map(fn {s, _pos} -> s end)
  end

  describe "sort control" do
    test "defaults to newest-first and renders the control when rows exist", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(view, "#downloads-sort")
      assert has_element?(view, "#downloads-sort option[value='added_desc'][selected]")
    end

    test "is hidden when the active tab has no rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      refute has_element?(view, "#downloads-sort")
    end

    test "offers tab-appropriate options", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")

      # Queue tab: ETA is meaningful, ratio is not.
      assert has_element?(view, "#downloads-sort option[value='eta_asc']")
      refute has_element?(view, "#downloads-sort option[value='ratio_desc']")

      html = view |> element("button[phx-value-tab='completed']") |> render_click()

      # Completed tab: ratio/imported are meaningful, ETA is not.
      assert html =~ "ratio_desc"
      assert has_element?(view, "#downloads-sort option[value='ratio_desc']")
      refute has_element?(view, "#downloads-sort option[value='eta_asc']")
    end
  end

  describe "sorting rows" do
    setup do
      completed_download("Gamma Movie", %{metadata: %{size: 3_000_000_000}})
      completed_download("Alpha Movie", %{metadata: %{size: 1_000_000_000}})
      completed_download("Beta Movie", %{metadata: %{size: 2_000_000_000}})
      :ok
    end

    test "sorts by name ascending and descending", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")
      titles = ["Alpha Movie", "Beta Movie", "Gamma Movie"]

      html = view |> element("#downloads-sort-form") |> render_change(%{"sort_by" => "name_asc"})
      assert order_in(html, titles) == ["Alpha Movie", "Beta Movie", "Gamma Movie"]
      assert has_element?(view, "#downloads-sort option[value='name_asc'][selected]")

      html = view |> element("#downloads-sort-form") |> render_change(%{"sort_by" => "name_desc"})
      assert order_in(html, titles) == ["Gamma Movie", "Beta Movie", "Alpha Movie"]
    end

    test "sorts by size descending (largest first)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      html = view |> element("#downloads-sort-form") |> render_change(%{"sort_by" => "size_desc"})

      assert order_in(html, ["Alpha Movie", "Beta Movie", "Gamma Movie"]) ==
               ["Gamma Movie", "Beta Movie", "Alpha Movie"]

      assert has_element?(view, "#downloads-sort option[value='size_desc'][selected]")
    end

    test "an unknown sort value leaves the current sort unchanged", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      # No crash, default remains selected.
      html = view |> element("#downloads-sort-form") |> render_change(%{"sort_by" => "bogus"})
      assert html =~ ~s(value="added_desc")
      assert has_element?(view, "#downloads-sort option[value='added_desc'][selected]")
    end
  end

  describe "clear completed modal" do
    test "opens with the delete-files checkbox off and a scope-accurate count", %{conn: conn} do
      completed_download("Alpha Movie")
      completed_download("Beta Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")

      refute has_element?(view, "#clear-completed-modal[open]")

      html =
        view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      assert has_element?(view, "#clear-completed-modal[open]")
      assert html =~ "2 completed download(s)"
      # Default (unchecked) confirm button is non-destructive.
      assert html =~ "Clear Completed"
      refute html =~ "Clear and Delete Files"
    end

    test "checking the box switches the confirm button to destructive", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      html =
        view |> element("#clear-completed-form") |> render_change(%{"delete_files" => "true"})

      assert html =~ "Clear and Delete Files"
      assert html =~ "btn-error"
      assert html =~ "cannot be undone"
    end

    test "reopening the modal resets the checkbox", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()
      view |> element("#clear-completed-form") |> render_change(%{"delete_files" => "true"})

      view
      |> element(".modal-action button[phx-click='close_clear_completed_modal']")
      |> render_click()

      html =
        view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      refute html =~ "Clear and Delete Files"
      assert html =~ "Clear Completed"
    end

    test "submitting without the box clears without deleting files", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      html = view |> element("#clear-completed-form") |> render_submit(%{})

      assert html =~ "completed download(s) cleared"
      refute html =~ "files deleted from disk"
      assert Downloads.count_completed() == 0
    end

    test "submitting with the box checked reports files deleted", %{conn: conn} do
      completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      html =
        view |> element("#clear-completed-form") |> render_submit(%{"delete_files" => "true"})

      assert html =~ "cleared and files deleted from disk"
      assert Downloads.count_completed() == 0
    end

    test "a readonly user cannot clear completed downloads", %{conn: conn} do
      completed_download("Alpha Movie")
      readonly = user_fixture(%{role: "readonly"})
      conn = log_in_user(conn, readonly)

      {:ok, view, _html} = live(conn, ~p"/downloads")
      view |> element("button[phx-click='open_clear_completed_modal']") |> render_click()

      html =
        view |> element("#clear-completed-form") |> render_submit(%{"delete_files" => "true"})

      assert html =~ "do not have permission"
      assert Downloads.count_completed() == 1
    end
  end

  describe "batch action authorization" do
    test "a readonly user cannot batch-delete downloads", %{conn: conn} do
      download = completed_download("Alpha Movie")
      readonly = user_fixture(%{role: "readonly"})
      conn = log_in_user(conn, readonly)

      {:ok, view, _html} = live(conn, ~p"/downloads")

      render_click(view, "toggle_select", %{"id" => download.id})
      render_click(view, "batch_delete", %{})

      # The download is untouched — the gate blocked the destructive handler.
      assert Downloads.count_completed() == 1
    end

    test "an admin can batch-delete downloads", %{conn: conn} do
      download = completed_download("Alpha Movie")

      {:ok, view, _html} = live(conn, ~p"/downloads")

      render_click(view, "toggle_select", %{"id" => download.id})
      render_click(view, "batch_delete", %{})

      assert Downloads.count_completed() == 0
    end

    test "a readonly user cannot batch-retry downloads", %{conn: conn} do
      download = completed_download("Alpha Movie")
      readonly = user_fixture(%{role: "readonly"})
      conn = log_in_user(conn, readonly)

      {:ok, view, _html} = live(conn, ~p"/downloads")

      render_click(view, "toggle_select", %{"id" => download.id})
      render_click(view, "batch_retry", %{})

      # batch_retry deletes-and-reinitiates on success; the gate must leave the
      # record untouched for a readonly user.
      assert Downloads.count_completed() == 1
    end
  end

  describe "post-import re-match (U4)" do
    defp imported_movie_with_file(old_title) do
      library = library_path_fixture(%{type: "movies", monitored: true})
      old = media_item_fixture(%{type: "movie", title: old_title})

      download =
        download_fixture(%{
          media_item_id: old.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, _media_file} =
        Library.create_media_file(%{
          relative_path: "#{old_title}/movie.mkv",
          library_path_id: library.id,
          media_item_id: old.id,
          size: 100,
          metadata: %{"imported_from_download_id" => download.id}
        })

      download
    end

    test "Re-match action is shown for an eligible imported row", %{conn: conn} do
      download = imported_movie_with_file("Wrong Title")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_click(view, "switch_tab", %{"tab" => "completed"})

      assert has_element?(
               view,
               "button[phx-click='open_match_modal'][phx-value-id='#{download.id}'][phx-value-mode='postimport']"
             )
    end

    test "Re-match action is hidden for an ineligible (partial_pack) row", %{conn: conn} do
      movie = media_item_fixture(%{type: "movie", title: "Pack"})

      download =
        download_fixture(%{
          media_item_id: movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
          match_status: "partial_pack"
        })

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_click(view, "switch_tab", %{"tab" => "completed"})

      refute has_element?(
               view,
               "button[phx-click='open_match_modal'][phx-value-id='#{download.id}']"
             )
    end

    test "Re-match action is hidden for a fully-imported multi-file pack", %{conn: conn} do
      # A season pack imports successfully, so MediaImport clears match_status to
      # nil — but it resolves to several imported files and can't be re-matched as
      # a unit. The action must stay hidden even though match_status is nil.
      library = library_path_fixture(%{type: "series", monitored: true})
      show = media_item_fixture(%{type: "tv_show", title: "Some Show"})

      download =
        download_fixture(%{
          media_item_id: show.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      for episode <- 1..2 do
        {:ok, _file} =
          Library.create_media_file(%{
            relative_path: "Some Show/S01E0#{episode}.mkv",
            library_path_id: library.id,
            media_item_id: show.id,
            size: 100,
            metadata: %{"imported_from_download_id" => download.id}
          })
      end

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_click(view, "switch_tab", %{"tab" => "completed"})

      refute has_element?(
               view,
               "button[phx-click='open_match_modal'][phx-value-id='#{download.id}'][phx-value-mode='postimport']"
             )
    end

    test "re-matching a movie enqueues the job and persists the new target", %{conn: conn} do
      download = imported_movie_with_file("Wrong Title")
      new_movie = media_item_fixture(%{type: "movie", title: "Corrected Title"})

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_click(view, "switch_tab", %{"tab" => "completed"})
      render_click(view, "open_match_modal", %{"id" => download.id, "mode" => "postimport"})

      assert has_element?(view, "#match-modal")

      render_change(view, "match_modal_search", %{"q" => "Corrected"})

      html =
        render_click(view, "match_modal_pick_item", %{
          "media_item_id" => new_movie.id,
          "type" => "movie",
          "title" => new_movie.title
        })

      assert html =~ "Re-match queued"
      assert_enqueued(worker: Mydia.Jobs.MediaRematch, args: %{"download_id" => download.id})
      assert Downloads.get_download!(download.id).media_item_id == new_movie.id
    end
  end

  describe "in-flight match correction (U3)" do
    test "Change match action is shown on an active (not-imported) row", %{conn: conn} do
      movie = media_item_fixture(%{type: "movie", title: "Active Movie"})
      download = download_fixture(%{media_item_id: movie.id, imported_at: nil})

      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(
               view,
               "button[phx-click='open_match_modal'][phx-value-id='#{download.id}'][phx-value-mode='inflight']"
             )
    end

    test "changing the match on an in-flight download persists the new target", %{conn: conn} do
      movie = media_item_fixture(%{type: "movie", title: "Active Movie"})
      new_movie = media_item_fixture(%{type: "movie", title: "Better Match"})
      download = download_fixture(%{media_item_id: movie.id, imported_at: nil})

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_click(view, "open_match_modal", %{"id" => download.id, "mode" => "inflight"})
      render_change(view, "match_modal_search", %{"q" => "Better"})

      render_click(view, "match_modal_pick_item", %{
        "media_item_id" => new_movie.id,
        "type" => "movie",
        "title" => new_movie.title
      })

      assert Downloads.get_download!(download.id).media_item_id == new_movie.id
    end
  end

  describe "import failure surfacing on the queue row" do
    test "import_issue/1 classifies the download's import state" do
      alias MydiaWeb.DownloadsLive.Index
      dt = DateTime.utc_now()

      assert Index.import_issue(%{
               imported_at: nil,
               import_failed_at: dt,
               import_last_error: "boom",
               import_next_retry_at: nil
             }) == :failed

      assert Index.import_issue(%{
               imported_at: nil,
               import_failed_at: dt,
               import_last_error: "boom",
               import_next_retry_at: dt
             }) == :retrying

      # Already imported: no problem to show even if a stale error lingers.
      assert Index.import_issue(%{
               imported_at: dt,
               import_failed_at: dt,
               import_last_error: "boom",
               import_next_retry_at: nil
             }) == nil

      # No import attempted yet.
      assert Index.import_issue(%{
               imported_at: nil,
               import_failed_at: nil,
               import_last_error: nil,
               import_next_retry_at: nil
             }) == nil
    end

    test "renders the import error on a completed-but-not-imported row", %{conn: conn} do
      # Mirrors the incident: the torrent finished but the import keeps failing.
      # The user must see the error on the activity list, not a healthy row.
      media_item = media_item_fixture(%{title: "Perm Fail Show"})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      download_fixture(%{
        media_item_id: media_item.id,
        title: "Perm.Fail.S01E01",
        completed_at: now,
        imported_at: nil,
        import_failed_at: now,
        import_last_error: "Download path is not accessible: /media/Series: permission denied",
        import_next_retry_at: DateTime.add(now, 3600, :second),
        import_retry_count: 2
      })

      {:ok, _view, html} = live(conn, ~p"/downloads")

      assert html =~ "Import retrying"
      assert html =~ "permission denied"
      assert html =~ "Attempt #2"
    end
  end

  describe "soft-stall vs terminal stall badge" do
    alias MydiaWeb.DownloadsLive.Index

    test "a soft-stalled download renders a warning 'Stalled' badge" do
      now = DateTime.utc_now()

      assert {"badge-warning", "Stalled"} =
               Index.status_badge(%{
                 status: "downloading",
                 stalled_since: now,
                 import_failed_at: nil,
                 import_last_error: nil
               })
    end

    test "a normal download falls through to its client-status badge" do
      assert {_class, "Downloading"} =
               Index.status_badge(%{
                 status: "downloading",
                 stalled_since: nil,
                 import_failed_at: nil,
                 import_last_error: nil
               })
    end

    test "a stale stalled_since on a no-longer-downloading row does not render the warning badge" do
      # A soft-stall that paused/completed keeps a lingering stalled_since (it is
      # only cleared while observed downloading). The badge must reflect the
      # current client status, not a stale warning.
      now = DateTime.utc_now()

      assert {_class, "Completed"} =
               Index.status_badge(%{
                 status: "completed",
                 stalled_since: now,
                 import_failed_at: nil,
                 import_last_error: nil
               })
    end
  end
end
