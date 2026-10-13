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

  alias Mydia.Repo
  alias MydiaWeb.AdminNav

  # Tables that must render with at least one row, so the stacked layout is
  # exercised rather than an empty-state alert.
  @tables %{
    "/admin/users" => "#users",
    "/admin/jobs" => "#cron-jobs",
    "/admin/release-blacklist" => "#blacklist",
    "/admin/plugins" => "#plugin-sources-table"
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

    :ok
  end

  # Every element outside the sidebar and dock that scrolls on its own, as
  # "Y client/scroll X client/scroll selector" lines. The document itself is
  # allowed to scroll and is skipped.
  defp independent_scrollers(session) do
    eval_js(session, """
    var out = [];
    var all = document.querySelectorAll('body *');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var s = getComputedStyle(el);
      if (el.getBoundingClientRect().width === 0) continue;
      if (s.display === 'none' || s.visibility === 'hidden') continue;
      if (el.closest('aside, .drawer-side, nav#mobile-dock')) continue;
      var y = /(auto|scroll)/.test(s.overflowY) && el.scrollHeight > el.clientHeight + 4;
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

  # The open dialog's box is allowed to scroll: it is the screen's one
  # scroller while it is open.
  defp independent_scrollers_in_dialog(session) do
    Enum.reject(independent_scrollers(session), &String.contains?(&1, ".modal-box"))
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
          line <- visit_liveview(session, path) && independent_scrollers(session) do
        "  #{path}: #{line}"
      end

    assert offenders == [],
           "regions that scroll on their own at 390px:\n" <> Enum.join(offenders, "\n")
  end

  @tag :feature
  test "the tables under test actually render rows", %{session: session} do
    login_as_admin(session)

    for {path, selector} <- @tables do
      visit_liveview(session, path)

      assert Wallaby.Browser.has_css?(session, "#{selector} tbody tr"),
             "#{path} rendered no #{selector} rows, so the scroll check proves nothing"
    end
  end

  @tag :feature
  test "admin dialogs are the only scroller while open", %{session: session} do
    login_as_admin(session)
    phone(session)

    for {path, opener} <- [
          {"/admin/indexers", ~s([phx-click="show_indexer_library"])},
          {"/admin/clients", ~s([phx-click="new_download_client"])},
          {"/admin/media-servers", ~s([phx-click="new_media_server"])}
        ] do
      visit_liveview(session, path)
      js_click(session, opener)
      assert Wallaby.Browser.has_css?(session, ".modal-open .modal-box")

      assert independent_scrollers_in_dialog(session) == [],
             "#{path} dialog: " <> inspect(independent_scrollers_in_dialog(session))
    end
  end
end
