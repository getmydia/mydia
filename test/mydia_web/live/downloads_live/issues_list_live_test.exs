defmodule MydiaWeb.DownloadsLive.IssuesListLiveTest do
  # Not async: the connected mount runs in another process (see index_test.exs).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.{ExternalScan, ExternalTorrent}

  setup %{conn: conn} do
    # The scan cache is global and other tests seed it without clearing.
    :ok = ExternalTorrents.put(ExternalScan.empty())
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp seed_import_failure_and_missing do
    item = media_item_fixture(%{title: "Fictional Salt Meridian"})
    other = media_item_fixture(%{title: "Fictional Copper Lantern"})

    failed =
      download_fixture(%{
        media_item_id: item.id,
        download_client: nil,
        download_client_id: nil,
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        import_last_error: "permission denied"
      })

    # Status is derived, not stored: a download with a client id that the
    # client no longer reports (no client is configured here) reads as missing.
    missing = download_fixture(%{media_item_id: other.id})

    %{failed: failed, missing: missing}
  end

  test "issues render as one list, without the old section cards", %{conn: conn} do
    %{failed: failed, missing: missing} = seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert view |> element("#issues-list") |> render() |> count_rows() == 2
    assert has_element?(view, "#issues-list > li#issues-#{failed.id}")
    assert has_element?(view, "#issues-list > li#issues-#{missing.id}")
    refute has_element?(view, "#issues-needs-matching")
    refute has_element?(view, "#issues-unresolved")
    refute has_element?(view, "#issues-other")
    refute has_element?(view, "#downloads-empty-state")
  end

  test "kind chips appear only for kinds that have issues", %{conn: conn} do
    seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert has_element?(view, "#issues-kind-import_failed")
    assert has_element?(view, "#issues-kind-missing")
    refute has_element?(view, "#issues-kind-download_failed")
  end

  test "?kind= shows only that kind, with a removable chip", %{conn: conn} do
    %{failed: failed, missing: missing} = seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&kind=missing")

    assert has_element?(view, "#issues-#{missing.id}")
    refute has_element?(view, "#issues-#{failed.id}")
    assert has_element?(view, "#downloads-filter-chip-kind")
    # The other chips still show what they would yield.
    assert has_element?(view, "#issues-kind-import_failed")
  end

  test "choosing a kind chip patches the URL", %{conn: conn} do
    seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    view
    |> element("#downloads-filter-form")
    |> render_change(%{"kind" => "import_failed"})

    assert_patch(view, ~p"/downloads?tab=issues&kind=import_failed")
  end

  test "removing the kind chip patches back to all issues", %{conn: conn} do
    seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&kind=missing")

    view |> element("#downloads-filter-chip-kind button") |> render_click()

    assert_patch(view, ~p"/downloads?tab=issues")
  end

  test "a torrent awaiting a match renders as a row with Match", %{conn: conn} do
    torrent = %ExternalTorrent{
      id: "t1",
      client_name: "qbit",
      client_id: "hash-t1",
      title: "Fictional.Salt.Meridian.S01E01.1080p.WEB-DL",
      kind: :needs_matching,
      status: :downloading,
      progress: 40.0,
      suggestions: []
    }

    :ok = ExternalTorrents.put(%{ExternalScan.empty() | needs_matching: [torrent]})

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert has_element?(view, "#issues-t1")
    refute has_element?(view, "#library-search-form-t1")

    view |> element("#issue-match-t1") |> render_click()

    assert has_element?(view, "#issues-t1 #library-search-form-t1")
  end

  test "opening Match never brings back a row the filters hide", %{conn: conn} do
    torrent = fn id, title ->
      %ExternalTorrent{
        id: id,
        client_name: "qbit",
        client_id: "hash-#{id}",
        title: title,
        kind: :needs_matching,
        status: :downloading,
        progress: 40.0,
        suggestions: []
      }
    end

    :ok =
      ExternalTorrents.put(%{
        ExternalScan.empty()
        | needs_matching: [
            torrent.("t1", "Fictional.Salt.Meridian.S01E01"),
            torrent.("t2", "Fictional.Copper.Lantern.S01E01")
          ]
      })

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")
    view |> element("#issue-match-t1") |> render_click()

    view |> element("#downloads-filter-form") |> render_change(%{"q" => "Copper"})
    refute has_element?(view, "#issues-t1")

    view |> element("#issue-match-t2") |> render_click()

    refute has_element?(view, "#issues-t1")
    assert has_element?(view, "#issues-t2 #library-search-form-t2")
  end

  test "the Issues tab badge counts every issue", %{conn: conn} do
    seed_import_failure_and_missing()

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&kind=missing")

    assert view |> element("#downloads-tab-issues-count") |> render() =~ ~r/>\s*2\s*</
  end

  test "with no issues, the tab shows the empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert has_element?(view, "#downloads-empty-state", "No issues")
    refute has_element?(view, "#issues-list > li")
  end

  defp count_rows(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#issues-list > li")
    |> Enum.count()
  end
end
