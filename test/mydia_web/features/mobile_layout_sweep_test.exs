defmodule MydiaWeb.Features.MobileLayoutSweepTest do
  @moduledoc """
  Every `live` route, at phone widths, in its default state and the states
  listed in `MydiaWeb.MobileLayoutManifest`, audited for the six defects
  (seven checks) in `lib/mydia_web/components/README.md`, "Mobile layout
  sweep".

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

  # Accepted violations: {route, width, check, selector, reason}. A failing
  # run's `accept with:` line pastes in as-is (an integer width); entries for
  # the same defect at several widths may group them as a list, and known/0
  # expands both forms. Selectors replace database ids with `*` (see
  # MobileLayout.audit/2). Grouped by route.
  @known [
    # /activity
    {"/activity", 320, :escapes_viewport,
     "#activity-date-filter button.btn.join-item.btn-sm.gap-1.5",
     "daisyUI join of date range buttons does not wrap"},
    {"/activity", 320, :page_overflow, "html",
     "daisyUI join of date range buttons does not wrap"},

    # /admin/dashboard
    {"/admin/dashboard", @all, :tiny_text, "#plays-chart text.fill-base-content/60",
     "chart axis labels are 10px SVG text"},

    # /admin/indexers
    {"/admin/indexers", @all, :small_target,
     "#cardigann-engine a.link.link-hover.text-xs.opacity-70",
     "standalone text-xs docs link is 16px tall"},

    # /admin/status
    {"/admin/status", @all, :small_target, "#status-system a.link.link-hover",
     "version link in the stat value is 19px tall"},

    # /admin/subtitle-providers
    {"/admin/subtitle-providers", 320, :page_overflow, "html",
     "hidden tooltips on the provider rows' badges widen the page"},

    # /admin/users
    {"/admin/users", 320, :escapes_viewport, "#user-* div",
     "unbroken username and email do not wrap in the user card"},
    {"/admin/users", 320, :page_overflow, "html",
     "unbroken username and email do not wrap in the user card"},

    # /collections/:id
    {"/collections/:id", 320, :escapes_viewport, "#phx-* div.dropdown.dropdown-end",
     "header actions menu is pushed past the edge by the long collection name"},

    # /downloads, Issues tab
    {"/downloads#issues", @all, :small_target, "#issue-open-*",
     "text-xs path button is 16px tall"},
    {"/downloads#issues", @all, :small_target, "#issues-* a.link.link-hover.font-medium.text-sm",
     "title link is 20px tall"},

    # /media/:id, /movies/:id and /tv/:id share the detail header
    {"/media/:id", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall"},
    {"/movies/:id", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall"},
    {"/movies/:id#manual-search", @all, :small_target, "#main-column button.group.cursor-pointer",
     "category badge button is 21px tall (still measured behind the dialog)"},

    # /requests
    {"/requests", 320, :escapes_viewport, "#phx-* a.btn.btn-primary",
     "Request Movie and Request Series buttons do not wrap"},
    {"/requests", 320, :page_overflow, "html",
     "Request Movie and Request Series buttons do not wrap"},

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
     "category badge button is 21px tall"}
  ]

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

    {unexpected, stale} = Report.diff(violations, known())

    assert unexpected == [] and stale == [],
           "Mobile layout sweep:\n\n" <> Report.format(unexpected, stale)
  end

  # Report entries, one per width.
  defp known do
    for {route, widths, check, selector, reason} <- @known,
        width <- List.wrap(widths),
        do: {route, width, check, selector, reason}
  end

  defp sweep_route(session, route, url, states) do
    default = audit_widths(session, route, url, nil, fn -> visit_at(session, url) end)

    state_violations =
      for {name, steps} <- states,
          v <-
            audit_widths(session, route, url, name, fn ->
              visit_at(session, url)
              run_steps(session, url, steps)
            end),
          do: v

    default ++ state_violations
  end

  # Loads once at the first width, audits, then resizes and audits again.
  defp audit_widths(session, route, url, state, load) do
    {w, h} = @first
    Wallaby.Browser.resize_window(session, w, h)
    load.()

    wait_for_settled(session)

    # A redirect (with a flash) would otherwise audit the page it landed on.
    expected = URI.parse(url).path
    actual = Wallaby.Browser.current_path(session)

    assert actual == expected,
           "#{route}#{if state, do: "#" <> state}: expected the browser on #{expected}, it is on #{actual}"

    for {width, height} <- [@first | @resized],
        %Violation{} = v <- audit_at(session, route, state, width, height) do
      %Violation{v | route: route, width: width, state: state}
    end
  end

  defp audit_at(session, route, state, width, height) do
    Wallaby.Browser.resize_window(session, width, height)
    # One frame for layout to settle after the resize.
    eval_js(
      session,
      "return new Promise(function (r) { requestAnimationFrame(function () { r(true); }); });"
    )

    assert_rendered(session, route, state, width)
    audit(session)
  end

  # An empty or blank page has nothing to measure and would pass every check,
  # so each audit first proves the layout's <main> holds a content box with
  # height and the dock has a box. (The [data-phx-main] root itself can be
  # display: contents, so its own rect says nothing.)
  @rendered_js """
  var main = document.querySelector("[data-phx-main] main");
  var dock = document.getElementById("mobile-dock");
  if (!main || !dock || dock.getBoundingClientRect().height === 0) return false;
  for (var c = main.firstElementChild; c; c = c.nextElementSibling) {
    if (c.getBoundingClientRect().height > 0) return true;
  }
  return false;
  """

  defp assert_rendered(session, route, state, width) do
    assert eval_js(session, @rendered_js),
           "#{route}#{if state, do: "#" <> state} @#{width}: the page content or the mobile dock has no box"
  end

  defp visit_at(session, url), do: visit_liveview(session, url)

  defp run_steps(session, url, steps) do
    Enum.each(steps, fn
      {:visit_query, query} -> visit_liveview(session, url <> "?" <> query)
      {:click, css} -> Wallaby.Browser.click(session, Wallaby.Query.css(css))
      {:wait, css} -> wait_for(session, css)
    end)
  end

  # Waits until no CSS transition is running, so a state step (the drawer
  # sliding in) is audited where it comes to rest, not mid-flight. Keyframe
  # animations (spinners, skeleton shimmer) may loop for good and are ignored.
  @settled_js """
  return document.getAnimations().every(function (a) {
    return !(a instanceof CSSTransition) || a.playState !== 'running';
  });
  """

  defp wait_for_settled(session) do
    eventually(
      fn -> if eval_js(session, @settled_js), do: {:ok, true}, else: :error end,
      description: "CSS transitions to finish"
    )
  end

  # Waits on the DOM rather than a Wallaby query, so the target may be a
  # hidden element (the drawer's checkbox).
  defp wait_for(session, css) do
    eventually(
      fn ->
        if eval_js(session, "return !!document.querySelector(arguments[0]);", [css]),
          do: {:ok, true},
          else: :error
      end,
      description: css
    )
  end
end
