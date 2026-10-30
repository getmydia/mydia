defmodule MydiaWeb.Features.MobileLayoutSweepTest do
  @moduledoc """
  Every `live` route, at phone widths, in its default state and the states
  listed in `MydiaWeb.MobileLayoutManifest`, audited for the six defects in
  `lib/mydia_web/components/README.md`, "Mobile layout sweep".

  `@known` lists accepted violations, each with a reason. A violation not on
  it fails, and so does an entry that no longer matches anything, so the list
  only shrinks.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature
  @moduletag timeout: :timer.minutes(15)
  # The seeded indexer is unreachable on purpose and logs its failed check.
  @moduletag :capture_log

  alias MydiaWeb.FeatureCase.MobileLayout.{Report, Violation}
  alias MydiaWeb.{MobileLayoutManifest, MobileLayoutSeed}

  @first {375, 812}
  @resized [{320, 640}, {414, 896}]

  @all [320, 375, 414]

  # Accepted violations: {route, widths, check, selector, reason}, expanded to
  # one Report entry per width by known/1. Selectors replace database ids with
  # `*` (see MobileLayout.audit/2). Grouped by route.
  @known [
    # /activity
    {"/activity", [320], :escapes_viewport,
     "#activity-date-filter button.btn.join-item.btn-sm.gap-1.5",
     "daisyUI join of date range buttons does not wrap"},
    {"/activity", [320], :page_overflow, "html",
     "daisyUI join of date range buttons does not wrap"},

    # /admin/dashboard
    {"/admin/dashboard", @all, :tiny_text, "#plays-chart text.fill-base-content/60",
     "chart axis labels are 10px SVG text"},

    # /admin/indexers
    {"/admin/indexers", @all, :small_target,
     "#cardigann-engine a.link.link-hover.text-xs.opacity-70",
     "standalone text-xs docs link is 16px tall"},
    {"/admin/indexers", @all, :tiny_text, "#add-more-library-indexers",
     "btn-xs text is under 12px"},
    {"/admin/indexers", @all, :tiny_text, "#cardigann-engine-toggle",
     "btn-xs text is under 12px"},
    {"/admin/indexers", @all, :tiny_text, "#indexer-stats-window-day",
     "btn-xs text is under 12px"},
    {"/admin/indexers", @all, :tiny_text, "#indexer-stats-window-week",
     "btn-xs text is under 12px"},

    # /admin/library-paths
    {"/admin/library-paths", [320], :escapes_viewport, "#library-path-* span.font-mono",
     "long library path in a font-mono span does not wrap"},

    # /admin/remote-access
    {"/admin/remote-access", @all, :tiny_text, "#admin-page-body span.badge.badge-xs.badge-ghost",
     "badge-xs text is under 12px"},

    # /admin/settings
    {"/admin/settings", @all, :small_target, "#language-prefer-default-track",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-auth-local_enabled input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-auth-oidc_enabled input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-auth-oidc_link_by_email input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-crash_reporting-enabled input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-feedback-enabled input.toggle.toggle-primary.toggle-sm", "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-library-auto_repair_enabled input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :small_target,
     "#setting-update_check-enabled input.toggle.toggle-primary.toggle-sm",
     "toggle-sm is 20px tall"},
    {"/admin/settings", @all, :tiny_text, "#admin-page-body span.badge.badge-ghost.badge-xs",
     "badge-xs text is under 12px"},
    {"/admin/settings", @all, :tiny_text, "#admin-page-body span.badge.badge-info.badge-xs",
     "badge-xs text is under 12px"},
    {"/admin/settings", @all, :tiny_text, "#admin-page-body span.badge.badge-primary.badge-xs",
     "badge-xs text is under 12px"},
    {"/admin/settings", @all, :tiny_text, "#admin-page-body span.badge.badge-xs.badge-secondary",
     "badge-xs text is under 12px"},

    # /admin/status
    {"/admin/status", @all, :small_target, "#status-system a.link.link-hover",
     "version link in the stat value is 19px tall"},

    # /admin/subtitle-providers
    {"/admin/subtitle-providers", @all, :small_target,
     "#subtitle-provider-toggle-registry::gestdown", "toggle-sm is 20px tall"},
    {"/admin/subtitle-providers", @all, :small_target,
     "#subtitle-provider-toggle-registry::relay", "toggle-sm is 20px tall"},
    {"/admin/subtitle-providers", @all, :tiny_text,
     "#subtitle-provider-row-gestdown span.badge.badge-ghost.badge-xs.tooltip",
     "badge-xs text is under 12px"},
    {"/admin/subtitle-providers", @all, :tiny_text,
     "#subtitle-provider-row-relay span.badge.badge-ghost.badge-xs.tooltip",
     "badge-xs text is under 12px"},

    # /admin/users
    {"/admin/users", [320], :escapes_viewport, "#user-* div",
     "unbroken username and email do not wrap in the user card"},
    {"/admin/users", [320], :page_overflow, "html",
     "unbroken username and email do not wrap in the user card"},

    # /calendar
    {"/calendar", @all, :tiny_text, "#phx-* button.btn.btn-primary.btn-xs.ml-2",
     "btn-xs text is under 12px"},

    # /discover
    {"/discover", @all, :small_target, "#discover-hide-owned", "toggle-sm is 20px tall"},

    # /downloads, Issues tab
    {"/downloads#issues", @all, :overlapping_targets,
     "#issues-* input.checkbox.checkbox-primary.checkbox-sm",
     "row checkbox overlaps the path button below it"},
    {"/downloads#issues", @all, :small_target, "#issue-open-*",
     "text-xs path button is 16px tall"},
    {"/downloads#issues", @all, :small_target, "#issues-* a.link.link-hover.font-medium.text-sm",
     "title link is 20px tall"},
    {"/downloads#issues", @all, :small_target,
     "#issues-* input.checkbox.checkbox-primary.checkbox-sm", "checkbox-sm is 20px"},

    # /import
    {"/import", @all, :small_target, "#auto-import-toggle", "toggle-sm is 20px tall"},

    # /media/:id, /movies/:id and /tv/:id share the detail header
    {"/media/:id", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall"},
    {"/movies/:id", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall"},

    # /movies, /sections/:id and /tv share the library grid (alphabet bar
    # letters are added by known/1)
    {"/movies", @all, :small_target, "#alpha-jump-q", "alphabet bar letter is 20x13"},
    {"/movies", @all, :small_target, "#alpha-jump-t", "alphabet bar letter is 20x13"},
    {"/movies", @all, :tiny_text, "#grid-item-* span.badge.inline-flex.items-center.badge-xs",
     "badge-xs text is under 12px"},
    {"/sections/:id", @all, :small_target, "#alpha-jump-q", "alphabet bar letter is 20x13"},
    {"/sections/:id", @all, :small_target, "#alpha-jump-t", "alphabet bar letter is 20x13"},
    {"/sections/:id", @all, :tiny_text,
     "#grid-item-* span.badge.inline-flex.items-center.badge-xs", "badge-xs text is under 12px"},
    {"/tv", @all, :small_target, "#alpha-jump-w", "alphabet bar letter is 20x13"},
    {"/tv", @all, :tiny_text, "#grid-item-* span.badge.inline-flex.items-center.badge-xs",
     "badge-xs text is under 12px"},

    # /profile
    {"/profile", @all, :small_target, "#phx-* label.label",
     "Theme label (for the picker) is 21px tall"},

    # /tv/:id
    {"/tv/:id", @all, :page_overflow, "html",
     "hidden tooltip-bottom on the right-aligned re-analyze button widens the page"},
    {"/tv/:id", @all, :small_target,
     "#episode-*-grid button.flex-1.min-w-0.cursor-pointer.text-left",
     "episode title button is 20px tall"},
    {"/tv/:id", @all, :small_target,
     "#episode-*-grid button.flex.items-center.gap-1.flex-shrink-0",
     "episode status button is 20px tall"},
    {"/tv/:id", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall"},
    {"/tv/:id", @all, :small_target, "#monitor-new-seasons-toggle", "checkbox-xs is 16px"},
    {"/tv/:id", @all, :tiny_text, "#segment-reanalyze-season-*", "btn-xs text is under 12px"}
  ]

  # On every swept page: the mobile dock.
  @chrome [
    {@all, :tiny_text, "#mobile-dock span.text-[10px].mt-0.5", "dock labels are text-[10px]"},
    {@all, :tiny_text, "#dock-player-link span.text-[10px].mt-0.5.opacity-70",
     "dock labels are text-[10px]"},
    {[320], :escapes_viewport, "#dock-player-link",
     "six min-w-[52px] dock items do not fit 320px"}
  ]

  # The alphabet jump bar renders every letter on the library grids.
  @alphabet_routes ["/movies", "/sections/:id", "/tv"]
  @alphabet Enum.map(?a..?z, &<<&1>>) ++ ["hash"]

  setup do
    # As admin_mobile_scroll_test.exs: keep the remote access page off the network.
    original = Application.get_env(:mydia, :direct_urls, [])
    Application.put_env(:mydia, :direct_urls, public_ip_enabled: false)
    on_exit(fn -> Application.put_env(:mydia, :direct_urls, original) end)

    # The Jobs page lists the cron schedule and needs a running Oban; see
    # test/README.md, "Oban is disabled in test".
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite

    start_supervised!(
      {Oban,
       repo: Mydia.Repo,
       engine: engine,
       testing: :disabled,
       queues: [],
       plugins: [{Oban.Cron, crontab: [{"0 0 1 1 *", Mydia.Jobs.HdrBackfill}]}]}
    )

    # Discover fetches genres on its connected mount; FeatureCase already warms
    # trending with an empty list.
    Mydia.MetadataCacheHelpers.warm_genre_cache(:movie, [])
    Mydia.MetadataCacheHelpers.warm_genre_cache(:tv_show, [])

    # The Indexers page reads the health cache this server owns; the app skips
    # it in test.
    start_supervised!(Mydia.Indexers.Health)

    admin = create_admin_user()
    {:ok, admin: admin, ids: MobileLayoutSeed.insert!(admin)}
  end

  @tag :feature
  test "every page fits a phone", %{session: session, admin: admin, ids: ids} do
    login(session, admin.username, "password123")

    swept =
      for {route, %{} = entry} <- Enum.sort(MobileLayoutManifest.entries()), do: {route, entry}

    violations =
      for {route, %{path: path, states: states}} <- swept,
          v <- sweep_route(session, route, path.(ids), states) do
        v
      end

    {unexpected, stale} = Report.diff(violations, known(swept))

    assert unexpected == [] and stale == [],
           "Mobile layout sweep:\n\n" <> Report.format(unexpected, stale)
  end

  # Report entries, one per width: the page-specific list, the dock on every
  # swept page and state, and the alphabet bar's letters.
  defp known(swept) do
    route_keys =
      for {route, %{states: states}} <- swept,
          key <- [route | Enum.map(states, fn {name, _steps} -> route <> "#" <> name end)],
          do: key

    page =
      for {route, widths, check, selector, reason} <- @known,
          width <- widths,
          do: {route, width, check, selector, reason}

    chrome =
      for route <- route_keys,
          {widths, check, selector, reason} <- @chrome,
          width <- widths,
          do: {route, width, check, selector, reason}

    alphabet =
      for route <- @alphabet_routes,
          width <- @all,
          letter <- @alphabet,
          do: {route, width, :tiny_text, "#alpha-jump-#{letter}", "alphabet bar letters are 10px"}

    page ++ chrome ++ alphabet
  end

  defp sweep_route(session, route, url, states) do
    default = audit_widths(session, route, nil, fn -> visit_at(session, url) end)

    state_violations =
      for {name, steps} <- states,
          v <-
            audit_widths(session, route, name, fn ->
              visit_at(session, url)
              run_steps(session, url, steps)
            end),
          do: v

    default ++ state_violations
  end

  # Loads once at the first width, audits, then resizes and audits again.
  defp audit_widths(session, route, state, load) do
    {w, h} = @first
    Wallaby.Browser.resize_window(session, w, h)
    load.()

    for {width, height} <- [@first | @resized],
        %Violation{} = v <- audit_at(session, width, height) do
      %Violation{v | route: route, width: width, state: state}
    end
  end

  defp audit_at(session, width, height) do
    Wallaby.Browser.resize_window(session, width, height)
    # One frame for layout to settle after the resize.
    eval_js(
      session,
      "return new Promise(function (r) { requestAnimationFrame(function () { r(true); }); });"
    )

    audit(session)
  end

  defp visit_at(session, url), do: visit_liveview(session, url)

  defp run_steps(session, url, steps) do
    Enum.each(steps, fn
      {:visit_query, query} -> visit_liveview(session, url <> "?" <> query)
      {:click, css} -> Wallaby.Browser.click(session, Wallaby.Query.css(css))
    end)
  end
end
