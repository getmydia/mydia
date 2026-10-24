defmodule MydiaWeb.Features.DownloadsIssuesMobileTest do
  @moduledoc """
  On a phone the Downloads Issues tab has one scroller: the page, or the open
  detail drawer.

  Measured at 390x844 before the redesign, the Issues tab was about 881px wide:
  the document overflowed sideways by 491px, because every row was a single
  non-wrapping flex line whose width was its longest unbroken title or error
  plus the action buttons beside it. The row actions (Match files, Retry
  removal, Dismiss) sat between 781px and 866px, out of reach without
  scrolling the whole page sideways.

  Seeds one issue of every kind, each with a long unbroken release title, a
  long error and a long unbroken client name, plus two Needs Matching torrents
  with long suggestion titles, so the page is measured under the worst
  realistic content.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  import Ecto.Query

  alias Mydia.Downloads.Structs.{ExternalScan, ExternalTorrent}
  alias Mydia.Downloads.{Download, ExternalTorrents}
  alias Mydia.DownloadsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.Repo

  @long_title "The.Quiet.Harbor.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10.H.265-FICTIONALGRP"
  @long_error String.duplicate("The remote client reported a fictional failure. ", 5)
  @long_path "/remote/very/long/path/to/the/fictional/downloads/directory/" <>
               "The.Quiet.Harbor.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10.H.265-FICTIONALGRP"
  @long_client "fictional-qbittorrent-seedbox-under-the-salt-meridian-archive-basement"

  # Primary action id prefixes per kind, followed by the issue id.
  @primary_action_prefixes ~w(issue-match match-files apply-mapping retry-import
                              retry-download dismiss retry-removal)

  # Elements of the rendered page whose right edge is past the viewport,
  # outside the sidebar and dock. `clipped` marks ones an ancestor already
  # clips or scrolls, which still count as a design problem on a phone.
  @offenders_js ~S"""
  var out = [];
  var vw = window.innerWidth;
  var all = document.querySelectorAll('body *');
  function label(el) {
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
      '.' + String(el.className && el.className.baseVal !== undefined ? el.className.baseVal : el.className)
        .trim().split(/\s+/).slice(0, 6).join('.');
  }
  for (var i = 0; i < all.length && out.length < 80; i++) {
    var el = all[i];
    var s = getComputedStyle(el);
    var r = el.getBoundingClientRect();
    if (r.width === 0 || s.display === 'none' || s.visibility === 'hidden') continue;
    if (el.closest('aside, .drawer-side, nav#mobile-dock')) continue;
    if (r.right <= vw + 1) continue;
    var clipped = false;
    for (var p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      var ps = getComputedStyle(p);
      if (ps.overflowX !== 'visible' && p.getBoundingClientRect().right <= vw + 1) {
        clipped = true;
        break;
      }
    }
    out.push(Math.round(r.right) + 'px ' + (clipped ? '(clipped) ' : '') + label(el));
  }
  return out;
  """

  # The open detail drawer's one allowed scroller: its modal box.
  @dialog_scroller_js ~S"""
  (function () {
    return document.querySelector('#download-detail[open] .modal-box');
  })()
  """

  setup do
    downloads = seed_issue_downloads()
    seed_needs_matching()
    {:ok, downloads: downloads, issue_count: map_size(downloads) + 2}
  end

  # One download per Issues kind, keyed by a label. The fixture owns creation,
  # then Repo.update_all forces the issue columns so changeset rules cannot
  # refuse them.
  defp seed_issue_downloads do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    [
      {"unresolved", [match_status: "unresolved_files"]},
      {"import-failed", [import_failed_at: now, import_last_error: @long_error]},
      {"path-mapping",
       [
         import_failed_at: now,
         import_last_error: @long_error,
         import_failure_reason: "path_mapping_mismatch",
         import_reported_path: @long_path
       ]},
      # `status` is derived, not stored: a download absent from its client is
      # "failed" when it carries an error_message and "missing" when it does not.
      {"download-failed", [error_message: @long_error]},
      {"missing", []},
      {"removal-failed", [removal_error: @long_error]},
      {"orphaned-client",
       [
         download_client: @long_client,
         error_message: "Download client '#{@long_client}' is no longer configured in Mydia.",
         import_failure_reason: "no_client"
       ]}
    ]
    |> Map.new(fn {kind, changes} ->
      media_item = MediaFixtures.media_item_fixture()

      download =
        DownloadsFixtures.download_fixture(%{
          media_item_id: media_item.id,
          title: "#{@long_title}.#{kind}"
        })

      if changes != [],
        do: Repo.update_all(from(d in Download, where: d.id == ^download.id), set: changes)

      {kind, download.id}
    end)
  end

  defp seed_needs_matching do
    # Each suggestion gets its own media item: the adopt button ids end in it.
    torrents =
      for n <- 1..2 do
        first = MediaFixtures.media_item_fixture()
        second = MediaFixtures.media_item_fixture()

        %ExternalTorrent{
          id: "fictional-needs-matching-#{n}",
          client_name: @long_client,
          client_id: "fictional-hash-#{n}",
          title: "#{@long_title}.needs.matching.#{n}",
          kind: :needs_matching,
          status: :completed,
          progress: 100.0,
          size: 4_000_000_000,
          suggestions: [
            %{
              media_item_id: first.id,
              title: "The Quiet Harbor of the Fictional Salt Meridian Archipelago (2021) #{n}",
              confidence: 0.92,
              match_reason: "title and year"
            },
            %{
              media_item_id: second.id,
              title: "The Quiet Harbor: A Considerably Longer Fictional Title For Wrapping #{n}",
              confidence: 0.61,
              match_reason: "title"
            }
          ]
        }
      end

    ExternalTorrents.put(%ExternalScan{needs_matching: torrents})
    on_exit(fn -> ExternalTorrents.put(ExternalScan.empty()) end)
  end

  defp phone(session), do: resize_window(session, 390, 844)

  # Every element outside the sidebar and dock that scrolls on its own, as
  # "Y client/scroll X client/scroll selector" lines. The document itself is
  # allowed to scroll and is skipped. With `exempt_dialog_scroller`, the open
  # drawer's box may scroll vertically; its sideways scrolling, and any
  # scroller nested inside it, are still reported.
  defp independent_scrollers(session, exempt_dialog_scroller \\ false) do
    eval_js(session, """
    var allowed = #{exempt_dialog_scroller} ? (#{@dialog_scroller_js}) : null;
    var out = [];
    var all = document.querySelectorAll('body *');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var s = getComputedStyle(el);
      if (el.getBoundingClientRect().width === 0) continue;
      if (s.display === 'none' || s.visibility === 'hidden') continue;
      if (el.closest('aside, .drawer-side, nav#mobile-dock')) continue;
      var y = /(auto|scroll)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 4;
      if (el === allowed) y = false;
      var x = /(auto|scroll)/.test(s.overflowX) && el.scrollWidth > el.clientWidth + 4;
      if (!(x || y)) continue;
      out.push((y ? 'Y ' + el.clientHeight + '/' + el.scrollHeight + ' ' : '') +
               (x ? 'X ' + el.clientWidth + '/' + el.scrollWidth + ' ' : '') +
               el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
               '.' + String(el.className).trim().split(/\\s+/).slice(0, 6).join('.'));
    }
    return out;
    """)
  end

  # Pixels by which the document itself overflows sideways, or 0.
  defp document_overflow(session) do
    eval_js(session, """
    var d = document.documentElement;
    return d.scrollWidth > d.clientWidth + 1 ? d.scrollWidth - d.clientWidth : 0;
    """)
  end

  # Pixels by which the open drawer's content is wider than the drawer, or 0.
  defp dialog_sideways_overflow(session) do
    eval_js(session, """
    var b = #{@dialog_scroller_js};
    return b.scrollWidth > b.clientWidth + 1 ? b.scrollWidth - b.clientWidth : 0;
    """)
  end

  defp offenders(session), do: eval_js(session, @offenders_js)

  defp issue_rows(session),
    do: eval_js(session, "return document.querySelectorAll('#issues-list > li').length;")

  # For each Issues row, its primary action as "row-id: right edge", flagged
  # when missing or past the viewport.
  defp unreachable_primary_actions(session) do
    eval_js(session, """
    var prefixes = #{Jason.encode!(@primary_action_prefixes)};
    var vw = window.innerWidth;
    var out = [];
    document.querySelectorAll('#issues-list > li').forEach(function (li) {
      var button = Array.prototype.find.call(li.querySelectorAll('button[id]'), function (b) {
        return prefixes.some(function (p) { return b.id.indexOf(p + '-') === 0; });
      });
      if (!button) { out.push(li.id + ': no primary action'); return; }
      var right = button.getBoundingClientRect().right;
      if (right > vw) out.push(li.id + ': #' + button.id + ' right edge ' + Math.round(right) + 'px');
    });
    return out;
    """)
  end

  defp measure(session) do
    %{
      document_overflow: document_overflow(session),
      scrollers: independent_scrollers(session),
      offenders: offenders(session)
    }
  end

  defp assert_fits(session, what) do
    m = measure(session)

    assert m.document_overflow == 0 and m.scrollers == [] and m.offenders == [],
           "#{what} does not fit 390px:\n#{inspect(m, pretty: true)}"
  end

  defp open_issues(session) do
    login_as_admin(session)
    phone(session)
    visit_liveview(session, "/downloads?tab=issues")
  end

  @tag :feature
  test "the Issues list renders every seeded issue", %{session: session, issue_count: count} do
    open_issues(session)

    assert issue_rows(session) == count,
           "expected #{count} rows in #issues-list, so the layout checks measure real rows"
  end

  # A badge has a fixed height: a name that wraps spills out of it vertically,
  # which no sideways measurement sees.
  @tag :feature
  test "a long client name stays inside its chip", %{session: session} do
    open_issues(session)

    spills =
      eval_js(session, """
      var out = [];
      document.querySelectorAll('#issues-list [id^="issue-client-"]').forEach(function (chip) {
        if (chip.scrollHeight > chip.clientHeight + 1 || chip.scrollWidth > chip.clientWidth + 1)
          out.push(chip.id + ' content ' + chip.scrollWidth + 'x' + chip.scrollHeight +
                   ' in ' + chip.clientWidth + 'x' + chip.clientHeight);
      });
      return out;
      """)

    assert spills == []
    assert Wallaby.Browser.has_css?(session, "#issue-client-fictional-needs-matching-1")
  end

  @tag :feature
  test "the Issues tab fits a phone with one scroller", %{session: session} do
    open_issues(session)

    assert document_overflow(session) == 0
    assert independent_scrollers(session) == []
    assert_fits(session, "the Issues tab")
    assert unreachable_primary_actions(session) == []
  end

  @tag :feature
  test "an open match search still fits a phone", %{session: session} do
    open_issues(session)

    js_click(session, "#issue-match-fictional-needs-matching-1")
    assert Wallaby.Browser.has_css?(session, "#issues-list button[id^='adopt-']")

    assert_fits(session, "the Issues tab with a match search open")
    assert unreachable_primary_actions(session) == []
  end

  @tag :feature
  test "the detail drawer is the only scroller while open", %{
    session: session,
    downloads: downloads
  } do
    open_issues(session)

    js_click(session, "#issue-open-#{downloads["path-mapping"]}")
    assert Wallaby.Browser.has_css?(session, "#download-detail[open] .modal-box")

    assert independent_scrollers(session, true) == [],
           "drawer: " <> inspect(independent_scrollers(session, true))

    assert dialog_sideways_overflow(session) == 0, "drawer content is wider than the drawer"
    assert document_overflow(session) == 0
  end

  @tag :feature
  test "the Downloads tab fits a phone", %{session: session} do
    login_as_admin(session)
    phone(session)
    visit_liveview(session, "/downloads")

    assert_fits(session, "the Downloads tab")
  end
end
