defmodule MydiaWeb.DownloadsLive.IssueListTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Structs.ExternalTorrent
  alias MydiaWeb.DownloadsLive.{Filters, Issue, IssueList}

  # Shaped like the enriched rows list_downloads_with_status/1 returns.
  defp download(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        title: "Fictional.Salt.Meridian.2031.1080p.WEB-DL-FICTGRP",
        status: "completed",
        match_status: nil,
        import_failed_at: nil,
        import_last_error: nil,
        import_retry_count: 0,
        import_next_retry_at: nil,
        import_failure_reason: nil,
        removal_error: nil,
        error_message: nil,
        download_client: "qbit",
        media_item_id: nil,
        media_item: nil,
        episode: nil,
        updated_at: ~U[2026-10-01 00:00:00Z]
      },
      Map.new(attrs)
    )
  end

  defp torrent(attrs) do
    struct!(
      ExternalTorrent,
      Keyword.merge(
        [
          id: "t1",
          client_name: "qbit",
          client_id: "c1",
          title: "Fictional.Lantern.S01E02-GRP",
          kind: :needs_matching,
          status: :seeding,
          progress: 1.0,
          parsed: nil
        ],
        attrs
      )
    )
  end

  describe "kind/1" do
    test "classifies each kind, first match wins" do
      now = ~U[2026-10-02 00:00:00Z]

      assert IssueList.kind(download(match_status: "unresolved_files", removal_error: "x")) ==
               :unresolved

      assert IssueList.kind(download(removal_error: "busy", import_failed_at: now)) ==
               :removal_failed

      assert IssueList.kind(download(import_failed_at: now, status: "failed")) == :import_failed
      assert IssueList.kind(download(status: "failed")) == :download_failed
      assert IssueList.kind(download(status: "missing")) == :missing
      assert IssueList.kind(download(status: "downloading")) == nil
    end
  end

  describe "build/2" do
    test "orders by kind, then most recent first, and drops non-issues" do
      old = download(status: "missing", updated_at: ~U[2026-01-01 00:00:00Z])
      new = download(status: "missing", updated_at: ~U[2026-05-01 00:00:00Z])
      failed = download(status: "failed")
      fine = download(status: "downloading")

      issues = IssueList.build([torrent([])], [old, fine, failed, new])

      assert Enum.map(issues, & &1.kind) == [
               :needs_matching,
               :download_failed,
               :missing,
               :missing
             ]

      assert Enum.map(Enum.take(issues, -2), & &1.id) == [new.id, old.id]
    end

    test "fills the row fields" do
      d =
        download(
          import_failed_at: ~U[2026-10-02 00:00:00Z],
          import_last_error: "Permission denied"
        )

      [issue] = IssueList.build([], [d])

      assert %Issue{kind: :import_failed, id: id, client: "qbit", download: ^d, torrent: nil} =
               issue

      assert id == d.id
      assert issue.reason == "Import failed: Permission denied"
      assert Issue.selectable?(issue)

      [scan_issue] = IssueList.build([torrent([])], [])
      assert scan_issue.torrent && is_nil(scan_issue.download)
      refute Issue.selectable?(scan_issue)
    end
  end

  test "counts/1 reports every kind" do
    counts = IssueList.build([], [download(status: "missing")]) |> IssueList.counts()
    assert counts.missing == 1
    assert counts.needs_matching == 0
    assert map_size(counts) == length(IssueList.kinds())
  end

  test "filter/2 applies kind, client and query" do
    issues =
      IssueList.build([torrent(client_name: "deluge")], [
        download(status: "missing", title: "Fictional.Harbor.2030"),
        download(status: "failed", download_client: "deluge")
      ])

    assert [%{kind: :missing}] = IssueList.filter(issues, %Filters{kind: :missing})
    assert length(IssueList.filter(issues, %Filters{client: "deluge"})) == 2
    assert [%{kind: :missing}] = IssueList.filter(issues, %Filters{q: "harbor"})
  end

  test "parse_kind/1 whitelists" do
    assert IssueList.parse_kind("import_failed") == :import_failed
    assert IssueList.parse_kind("bogus") == nil
    assert IssueList.parse_kind(nil) == nil
  end
end
