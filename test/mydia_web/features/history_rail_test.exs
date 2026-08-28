defmodule MydiaWeb.Features.HistoryRailTest do
  @moduledoc """
  Browser regression for the History rail's layout.

  The shipped rail turned on at the `xl:` VIEWPORT breakpoint, but this page
  never gets the viewport: `Layouts.app/1`'s sidebar is a hard `w-64` that is
  always open at lg and up, so the grid only ever has about
  `viewport - 256 - 64` to work with. Measured at a 1280px window, that left
  the main content column at 225px, narrower than either rail, with 25
  elements inside it overflowing past its right edge and two of the title's
  four action buttons landing underneath the rail itself.

  The rail's `sticky` also never pinned. Measured top offsets at 1300px were
  64 at rest, 0 mid-scroll and -48 at the page bottom, never the intended 16.

  A class-presence assertion cannot see any of that: the class was always
  there. This asks the browser for real rectangles at two window sizes.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Events

  # Every probe returns a distinct string when its target is missing or
  # zero-sized, so a selector typo fails loudly instead of silently no-opping.

  @track_count """
  const grid = document.querySelector('#page-grid');
  if (!grid) { return 'no grid rendered'; }
  const tracks = getComputedStyle(grid).gridTemplateColumns.trim();
  if (!tracks || tracks === 'none') { return 'grid has no column template'; }
  return tracks.split(/\\s+/).length;
  """

  @track_widths """
  const grid = document.querySelector('#page-grid');
  if (!grid) { return 'no grid rendered'; }
  return getComputedStyle(grid).gridTemplateColumns.trim()
    .split(/\\s+/).map(function (t) { return Math.round(parseFloat(t)); });
  """

  @rail_top """
  const rail = document.querySelector('#history-rail');
  if (!rail) { return 'no rail rendered'; }
  const r = rail.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return 'rail has no size'; }
  return Math.round(r.top);
  """

  @rail_height """
  const rail = document.querySelector('#history-rail');
  if (!rail) { return 'no rail rendered'; }
  const r = rail.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return 'rail has no size'; }
  return [Math.round(r.height), document.documentElement.clientHeight];
  """

  # elementFromPoint down the sidebar's centre. Any answer outside the sidebar
  # is page content painting over the chrome, which is the shape of the
  # originally reported "overlaps the left sidebar".
  @sidebar_probe """
  const side = document.querySelector('.drawer-side');
  if (!side) { return ['no sidebar rendered']; }
  const r = side.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return ['sidebar has no size']; }
  const problems = [];
  const x = r.left + r.width / 2;
  for (let i = 1; i <= 9; i++) {
    const y = r.top + r.height * i / 10;
    const hit = document.elementFromPoint(x, y);
    if (!hit) { problems.push('nothing at y=' + Math.round(y)); continue; }
    if (!side.contains(hit)) {
      problems.push('sidebar lost at y=' + Math.round(y) + ' to ' +
        hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : ''));
    }
  }
  return problems;
  """

  # Anything inside the main column whose right edge is past the column's own
  # right edge. Descendants of a deliberate `.overflow-x-auto` scroller are
  # excluded: those are clipped by design.
  @spill_probe """
  const col = document.querySelector('#main-column');
  if (!col) { return ['no main column rendered']; }
  const cr = col.getBoundingClientRect();
  if (cr.width < 1) { return ['main column has no width']; }
  const problems = [];
  const all = col.querySelectorAll('*');
  for (let i = 0; i < all.length; i++) {
    const el = all[i];
    if (el.closest('.overflow-x-auto')) continue;
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.right > cr.right + 1) {
      problems.push(el.tagName.toLowerCase() +
        (el.id ? '#' + el.id : '') + ' over by ' + Math.round(r.right - cr.right));
    }
  }
  return problems;
  """

  setup do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    :ok
  end

  @tag :feature
  test "past the threshold the rail is a third column that pins while scrolling",
       %{session: session} do
    show = seed_show_with_history()

    session
    |> login_as_admin()
    |> resize_window(1700, 1000)
    |> visit("/media/#{show.id}")
    |> wait_for_liveview()

    assert probe(session, @track_count) == 3

    # At 1700px the old `xl:` breakpoint also fires, so @track_count == 3
    # holds under old code too and does not discriminate old from new. The
    # assertion that actually does is `rail == 320`: the old layout used a
    # 22rem / 352px rail track, not the 20rem / 320px track this branch adds.
    [poster, main, rail] = probe(session, @track_widths)
    assert poster == 320, "poster column is #{poster}px, expected a 20rem track"
    assert rail == 320, "History rail is #{rail}px, expected a 20rem track"

    assert main > poster,
           "main content column is #{main}px, narrower than the #{poster}px poster column"

    [height, viewport] = probe(session, @rail_height)

    assert height <= viewport - 32,
           "rail is #{height}px tall in a #{viewport}px viewport, so sticky cannot pin"

    assert probe(session, @sidebar_probe) == []
    assert probe(session, @spill_probe) == []

    scroll_to_bottom(session)

    assert probe(session, @rail_top) == 16,
           "the rail did not stay pinned at top-4 after scrolling"

    assert probe(session, @sidebar_probe) == []
  end

  @tag :feature
  test "below the threshold there is no third column and nothing overflows",
       %{session: session} do
    show = seed_show_with_history()

    session
    |> login_as_admin()
    |> resize_window(1300, 1000)
    |> visit("/media/#{show.id}")
    |> wait_for_liveview()

    assert probe(session, @track_count) == 2

    [poster, main] = probe(session, @track_widths)

    assert main > poster,
           "main content column is #{main}px, narrower than the #{poster}px poster column"

    assert probe(session, @spill_probe) == []
    assert probe(session, @sidebar_probe) == []
  end

  defp probe(session, script) do
    execute_script(session, script, [], fn result -> send(self(), {:probe, result}) end)

    assert_receive {:probe, result}, 5_000
    result
  end

  defp scroll_to_bottom(session) do
    execute_script(
      session,
      "window.scrollTo(0, document.body.scrollHeight); return 'ok';",
      [],
      fn _ -> :ok end
    )

    session
  end

  defp seed_show_with_history do
    tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Fixture Rail Show",
        year: 2014,
        tmdb_id: tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    # Unwarmed, the recommendations load leaves the VM for the production
    # metadata relay during tests.
    warm_recommendations_cache(tmdb_id, :tv_show, [])

    # More than the collapsed cap of five, so the rail is at its full
    # collapsed height and the Show-more control is rendered.
    for i <- 1..8 do
      {:ok, _} =
        Events.create_event(%{
          category: "downloads",
          type: "download.completed",
          actor_type: :system,
          actor_id: "test",
          resource_type: "media_item",
          resource_id: show.id,
          metadata: %{"title" => "Fixture Release #{i}"}
        })
    end

    show
  end
end
