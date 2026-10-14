defmodule MydiaWeb.Features.AdminMobileScrollTest do
  @moduledoc """
  On a phone an admin screen has one scroller: the page, or the open dialog.

  Measured at 390x844 before the fix, every admin page scrolled the hub tab
  strip sideways (26% to 57% of tabs hidden), the Users, Jobs, Plugins and
  Release blacklist tables scrolled sideways inside the page, and the Indexer
  Library dialog scrolled a list inside an already scrolling dialog. Swipes
  moved whichever region happened to be under the finger.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  alias Mydia.Events
  alias Mydia.Repo
  alias Mydia.Settings
  alias MydiaWeb.AdminNav

  @guest_fixture Path.expand("../../support/fixtures/plugins/host_test_fixture.wasm", __DIR__)

  # Tables that must render with at least one row, so the stacked layout is
  # exercised rather than an empty-state alert, and a value seeded (or always
  # present) that must be visible in it.
  @tables %{
    "/admin/users" => {"#users", "alexandria.longusername"},
    "/admin/jobs" => {"#cron-jobs", "Mydia.Jobs.HdrBackfill"},
    "/admin/release-blacklist" => {"#blacklist", "The.Quiet.Harbor.S01E01"},
    "/admin/plugins" => {"#plugin-sources-table", "Official"}
  }

  setup do
    # The remote access page otherwise reaches icanhazip/ifconfig.me/ipify for real.
    original_direct_urls_config = Application.get_env(:mydia, :direct_urls, [])
    Application.put_env(:mydia, :direct_urls, public_ip_enabled: false)

    on_exit(fn ->
      Application.put_env(:mydia, :direct_urls, original_direct_urls_config)
    end)

    # The Jobs page lists the cron schedule, which needs a running Oban with a
    # Cron plugin. The app skips Oban in test, so start one with a crontab whose
    # entry cannot fire (see test/README.md, "Oban is disabled in test").
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite

    start_supervised!(
      {Oban,
       repo: Mydia.Repo,
       engine: engine,
       testing: :disabled,
       queues: [],
       plugins: [{Oban.Cron, crontab: [{"0 0 1 1 *", Mydia.Jobs.HdrBackfill}]}]}
    )

    insert(:user,
      username: "alexandria.longusername",
      email: "alexandria.longusername@example.test"
    )

    Repo.insert!(%Mydia.Downloads.ReleaseBlacklist{
      indexer: "Fictional Usenet Indexer With A Long Name",
      guid: "https://indexer.example/details/" <> String.duplicate("a1b2c3", 6),
      title: "The.Quiet.Harbor.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10.H.265-FICTIONALGRP",
      failure_reason: "Import failed: sample file detected, archive password protected",
      inserted_at: DateTime.utc_now()
    })

    for {id, name} <- [
          {"fictional-tracker-one", "The Fictional Lantern Mirror Network"},
          {"fictional-tracker-two", "Saltmarsh Example Tracker"},
          {"fictional-tracker-three", "Westmarch Example Semi-Private"}
        ] do
      Repo.insert!(%Mydia.Indexers.CardigannDefinition{
        indexer_id: id,
        name: name,
        description: "A fictional tracker definition with a long description for wrapping",
        language: "en-US",
        type: "public",
        links: %{},
        capabilities: %{},
        definition: "",
        schema_version: "11",
        enabled: true,
        in_library: false
      })
    end

    seed_plugin_with_network_log()

    :ok
  end

  # A plugin whose Logs dialog has a Network tab with a few recorded requests.
  defp seed_plugin_with_network_log do
    slug = "fictional-relay-plugin"

    {:ok, _} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: "Fictional Relay Plugin",
        version: "1.0.0",
        manifest: %{
          "slug" => slug,
          "name" => "Fictional Relay Plugin",
          "version" => "1.0.0",
          "capabilities" => %{"net:http" => ["relay.example"]}
        },
        wasm_module: File.read!(@guest_fixture),
        granted_capabilities: %{"net:http" => ["relay.example"]},
        enabled: false
      })

    for {outcome, status} <- [{"ok", 200}, {"ok", 204}, {"denied", nil}] do
      {:ok, _} =
        Events.create_event(%{
          category: "plugin",
          type: "plugin.http_request",
          actor_type: :system,
          actor_id: slug,
          severity: if(status, do: :info, else: :warning),
          metadata: %{
            "slug" => slug,
            "method" => "GET",
            "url" => "https://relay.example/v1/" <> String.duplicate("segment/", 8),
            "host" => "relay.example",
            "status" => status,
            "bytes" => 2048,
            "duration_ms" => 123,
            "outcome" => outcome
          }
        })
    end

    :ok
  end

  @dialog_scroller_js ~S"""
  (function () {
    var box = document.querySelector('.modal-open .modal-box');
    return box && (box.querySelector(':scope > [id$="-body"]') || box);
  })()
  """

  # Every element outside the sidebar and dock that scrolls on its own, as
  # "Y client/scroll X client/scroll selector" lines. The document itself is
  # allowed to scroll and is skipped.
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

  # The open dialog's one allowed scroller is its body (the element admin_modal
  # scrolls between the fixed header and the action row), or the box itself for
  # dialogs without one. Only its vertical scrolling is exempt: sideways
  # scrolling, and any scroller nested inside it, are still reported.
  defp independent_scrollers_in_dialog(session), do: independent_scrollers(session, true)

  # Pixels by which the open dialog's scroller is wider than itself, or 0.
  defp dialog_sideways_overflow(session) do
    eval_js(session, """
    var b = #{@dialog_scroller_js};
    return b.scrollWidth > b.clientWidth + 1 ? b.scrollWidth - b.clientWidth : 0;
    """)
  end

  # Pixels by which the document itself overflows sideways, or 0.
  defp document_overflow(session) do
    eval_js(session, """
    var d = document.documentElement;
    return d.scrollWidth > d.clientWidth + 1 ? d.scrollWidth - d.clientWidth : 0;
    """)
  end

  defp page_offenders(session, path) do
    visit_liveview(session, path)

    case document_overflow(session) do
      0 -> independent_scrollers(session)
      n -> ["document overflows by #{n}px" | independent_scrollers(session)]
    end
  end

  defp admin_paths do
    AdminNav.pages() |> Enum.filter(&AdminNav.visible?/1) |> Enum.map(& &1.path)
  end

  defp phone(session) do
    {w, h} = {390, 844}
    resize_window(session, w, h)
  end

  @tag :feature
  test "no admin page scrolls a region of its own on a phone", %{session: session} do
    login_as_admin(session)
    phone(session)

    offenders =
      for path <- admin_paths(),
          line <- page_offenders(session, path) do
        "  #{path}: #{line}"
      end

    assert offenders == [],
           "regions that scroll on their own at 390px:\n" <> Enum.join(offenders, "\n")
  end

  @tag :feature
  test "the tables under test actually render rows", %{session: session} do
    login_as_admin(session)
    phone(session)

    for {path, {selector, text}} <- @tables do
      visit_liveview(session, path)

      assert Wallaby.Browser.has_css?(session, "#{selector} tbody tr"),
             "#{path} rendered no #{selector} rows, so the scroll check proves nothing"

      Wallaby.Browser.assert_text(session, Wallaby.Query.css(selector), text)
    end
  end

  @tag :feature
  test "admin dialogs are the only scroller while open", %{session: session} do
    login_as_admin(session)
    phone(session)

    for {path, opener, prepare} <- [
          {"/admin/indexers", ~s([phx-click="show_indexer_library"]), nil},
          {"/admin/clients", ~s([phx-click="new_download_client"]), nil},
          {"/admin/media-servers", ~s([phx-click="new_media_server"]), nil},
          {"/admin/plugins", "#logs-fictional-relay-plugin", "#logs-tab-network"}
        ] do
      visit_liveview(session, path)
      js_click(session, opener)
      assert Wallaby.Browser.has_css?(session, ".modal-open .modal-box")

      if prepare do
        js_click(session, prepare)
        assert Wallaby.Browser.has_css?(session, "#plugin-net tr:not(.hidden)")
      end

      assert independent_scrollers_in_dialog(session) == [],
             "#{path} dialog: " <> inspect(independent_scrollers_in_dialog(session))

      assert dialog_sideways_overflow(session) == 0,
             "#{path} dialog content is wider than the dialog"
    end
  end
end
