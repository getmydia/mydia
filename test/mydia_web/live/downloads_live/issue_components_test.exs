defmodule MydiaWeb.DownloadsLive.IssueComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.DownloadsLive.{Issue, IssueComponents, IssueList}

  defp counts(overrides) do
    IssueList.kinds()
    |> Map.new(fn {kind, _label} -> {kind, 0} end)
    |> Map.merge(overrides)
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp render_row(issue, overrides \\ []) do
    assigns =
      Keyword.merge(
        [
          issue: issue,
          id: "issues-#{issue.id}",
          selection_mode: false,
          selected?: false,
          client_url: nil,
          search_open?: false,
          library_search_value: "",
          library_search_results: []
        ],
        overrides
      )

    html = render_component(&IssueComponents.issue_row/1, assigns)
    LazyHTML.from_fragment(html)
  end

  defp download(overrides) do
    Map.merge(
      %{
        id: "d1",
        title: "Fictional.Harbor",
        download_client: "qbit",
        import_retry_count: 2,
        import_next_retry_at: nil,
        path_mapping_suggestion: nil,
        path_mapping_affected_count: nil,
        import_failure_reason: nil
      },
      overrides
    )
  end

  defp download_issue(kind, overrides \\ %{}) do
    %Issue{
      kind: kind,
      id: "d1",
      title: "Fictional Harbor",
      reason: "Something went wrong",
      client: "qbit",
      download: download(overrides)
    }
  end

  describe "kind_filter/1" do
    test "hides empty kinds unless selected" do
      html =
        render_component(&IssueComponents.kind_filter/1,
          counts: counts(%{missing: 2}),
          selected: :unresolved
        )

      doc = LazyHTML.from_fragment(html)

      assert count(doc, "#issues-kind-missing") == 1
      assert count(doc, "#issues-kind-unresolved[checked]") == 1
      assert count(doc, "#issues-kind-import_failed") == 0
      assert count(doc, "input[name=kind][value=''][aria-label=All]") == 1
    end

    test "puts the count in the label" do
      html =
        render_component(&IssueComponents.kind_filter/1,
          counts: counts(%{import_failed: 3}),
          selected: nil
        )

      doc = LazyHTML.from_fragment(html)
      assert count(doc, "#issues-kind-import_failed[aria-label='Import failed 3']") == 1
    end
  end

  describe "issue_row/1" do
    test "an import failure with a mapping suggestion offers Apply mapping & retry" do
      issue =
        download_issue(:import_failed, %{
          path_mapping_suggestion: %{remote_prefix: "/r", local_prefix: "/l"},
          path_mapping_affected_count: 1,
          import_failure_reason: "path_mapping_mismatch"
        })

      doc = render_row(issue)

      assert count(doc, "#apply-mapping-d1[phx-click=apply_mapping_and_retry]") == 1
      assert count(doc, "#retry-import-d1") == 0
      assert count(doc, "#issue-open-d1[phx-click=open_details]") == 1
      assert count(doc, "#issue-menu-list-d1") == 1
    end

    test "an import failure without a suggestion offers Retry import" do
      doc = render_row(download_issue(:import_failed))
      assert count(doc, "#retry-import-d1[phx-click=retry_import]") == 1
    end

    test "an import failure keeps Match files in the menu; other kinds do not" do
      doc = render_row(download_issue(:import_failed))
      assert count(doc, "#issue-menu-match-files-d1[phx-click=open_match_files]") == 1

      doc = render_row(download_issue(:download_failed))
      assert count(doc, "#issue-menu-match-files-d1") == 0
    end

    test "needs-matching rows have no checkbox and offer Match" do
      torrent = %Mydia.Downloads.Structs.ExternalTorrent{
        id: "t1",
        title: "Fictional.Lantern",
        client_name: "qbit",
        client_id: "c1",
        kind: :needs_matching,
        status: :seeding,
        suggestions: []
      }

      issue = %Issue{
        kind: :needs_matching,
        id: "t1",
        title: "Fictional.Lantern",
        reason: "No library match",
        client: "qbit",
        torrent: torrent
      }

      doc = render_row(issue, selection_mode: true)

      assert count(doc, "input[type=checkbox]") == 0
      assert count(doc, "#issue-match-t1[phx-click=toggle_search]") == 1
      assert count(doc, "#issue-menu-list-t1") == 0
    end

    test "needs-matching suggestions render when the search is open" do
      torrent = %Mydia.Downloads.Structs.ExternalTorrent{
        id: "t1",
        title: "Fictional.Lantern",
        client_name: "qbit",
        client_id: "c1",
        kind: :needs_matching,
        status: :seeding,
        suggestions: [
          %{media_item_id: "m1", title: "Fictional Lantern", confidence: 0.9, match_reason: "x"}
        ]
      }

      issue = %Issue{
        kind: :needs_matching,
        id: "t1",
        title: "Fictional.Lantern",
        reason: "No library match",
        client: "qbit",
        torrent: torrent
      }

      doc = render_row(issue, search_open?: true)
      assert count(doc, "#adopt-t1-m1[phx-click=adopt_suggestion]") == 1
      assert doc |> LazyHTML.query("#adopt-t1-m1 .badge") |> LazyHTML.text() =~ "90%"
      refute doc |> LazyHTML.query("#adopt-t1-m1 .badge") |> LazyHTML.text() =~ "90.0"
    end

    test "unresolved rows offer Match files" do
      doc = render_row(download_issue(:unresolved))
      assert count(doc, "#match-files-d1[phx-click=open_match_files]") == 1
      assert count(doc, "input[type=checkbox]") == 1
    end

    test "download failures offer Retry" do
      doc = render_row(download_issue(:download_failed))
      assert count(doc, "#retry-download-d1[phx-click=retry_download]") == 1
    end

    test "missing rows offer Dismiss and the menu does not repeat it" do
      doc = render_row(download_issue(:missing))
      assert count(doc, "#dismiss-d1[phx-click=dismiss_download]") == 1
      assert count(doc, "#issue-menu-list-d1 [phx-click=dismiss_download]") == 0
      assert count(doc, "#issue-menu-list-d1 [phx-click=open_details]") == 1
    end

    test "removal failures offer Retry removal" do
      doc = render_row(download_issue(:removal_failed))
      assert count(doc, "#retry-removal-d1[phx-click=retry_removal]") == 1
      assert count(doc, "#issue-menu-list-d1 [phx-click=dismiss_download]") == 1
    end

    test "the title links to the media item when known" do
      issue = %{download_issue(:download_failed) | media_item_id: "m9"}
      doc = render_row(issue)
      assert count(doc, "a[href='/media/m9']") == 1
    end
  end

  describe "removed_client_alert/1" do
    test "renders the clear button with its ids" do
      group = %{slug: "old-qbit", count: 3, download_client: "old-qbit"}
      html = render_component(&IssueComponents.removed_client_alert/1, group: group)
      doc = LazyHTML.from_fragment(html)

      assert count(doc, "#removed-client-old-qbit") == 1
      assert count(doc, "#clear-removed-client-old-qbit[phx-click=clear_removed_client]") == 1
    end
  end
end
