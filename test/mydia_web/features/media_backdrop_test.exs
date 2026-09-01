defmodule MydiaWeb.Features.MediaBackdropTest do
  @moduledoc """
  Browser regression for the media detail page's backdrop.

  The shipped backdrop was two `absolute inset-0` layers inside the wrapper
  that holds the whole page grid, so its containing block was the page rather
  than the viewport. That produced every symptom reported in discussion #642:
  `object-cover` in a box 3000 to 4000px tall upscaled a 1920x1080 backdrop
  about 3x, the gradient was stretched across that same height so it never
  finished, and both layers stopped at the wrapper's bottom edge, which landed
  wherever the content happened to end.

  A class-presence assertion cannot see any of that. This asks the browser for
  real rectangles, at rest and at the page bottom, and checks the layer neither
  covers the app chrome nor swallows clicks.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Events

  # Every probe returns a distinct string when its target is missing or
  # zero-sized, so a selector typo fails loudly instead of silently no-opping.

  @backdrop_position """
  const el = document.querySelector('#page-backdrop');
  if (!el) { return 'no backdrop rendered'; }
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return 'backdrop has no size'; }
  return getComputedStyle(el).position;
  """

  # top, left, height, viewport height, full page height.
  @backdrop_metrics """
  const el = document.querySelector('#page-backdrop');
  if (!el) { return 'no backdrop rendered'; }
  const r = el.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return 'backdrop has no size'; }
  const doc = document.documentElement;
  return [Math.round(r.top), Math.round(r.left), Math.round(r.height),
          doc.clientHeight, doc.scrollHeight];
  """

  # A full-viewport layer must not intercept pointer events over page content.
  @backdrop_not_clickable """
  const el = document.querySelector('#page-backdrop');
  if (!el) { return 'no backdrop rendered'; }
  const col = document.querySelector('#main-column');
  if (!col) { return 'no main column rendered'; }
  const r = col.getBoundingClientRect();
  if (r.width < 1 || r.height < 1) { return 'main column has no size'; }
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + 20);
  if (!hit) { return 'nothing at the probe point'; }
  return el.contains(hit) ? 'backdrop intercepted the point' : 'ok';
  """

  # elementFromPoint down the sidebar's centre. A fixed full-viewport layer is
  # exactly the shape of thing that could paint over the chrome, so this guards
  # the z-order rather than assuming it.
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

  setup do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    :ok
  end

  @tag :feature
  test "the backdrop is anchored to the viewport and stays there while scrolling",
       %{session: session} do
    show = seed_show_with_backdrop()

    session
    |> login_as_admin()
    |> resize_window(1700, 800)
    |> visit("/media/#{show.id}")
    |> wait_for_liveview()

    assert eval_js(session, @backdrop_position) == "fixed"

    [top, left, height, viewport, page] = eval_js(session, @backdrop_metrics)

    # Without a page taller than the viewport the height assertion below is
    # vacuous: a short page makes page height and viewport height agree even
    # under the old absolute layer.
    assert page > viewport * 3 / 2,
           "page is #{page}px in a #{viewport}px viewport, too short to tell " <>
             "a viewport-sized backdrop from a page-sized one"

    assert top == 0, "backdrop top is #{top}, expected 0"

    assert left == 256,
           "backdrop left is #{left}, expected 256 to clear the w-64 sidebar"

    assert abs(height - viewport) <= 2,
           "backdrop is #{height}px tall in a #{viewport}px viewport " <>
             "(page is #{page}px), so it is sized to the page, not the screen"

    assert eval_js(session, @sidebar_probe) == []
    assert eval_js(session, @backdrop_not_clickable) == "ok"

    scroll_to_bottom(session)

    [scrolled_top, _, scrolled_height, _, _] = eval_js(session, @backdrop_metrics)

    assert scrolled_top == 0,
           "backdrop top is #{scrolled_top} at the page bottom, so it scrolled away"

    assert abs(scrolled_height - viewport) <= 2,
           "backdrop is #{scrolled_height}px tall at the page bottom"

    assert eval_js(session, @sidebar_probe) == []
  end

  @tag :feature
  test "below the lg breakpoint the backdrop spans the full width", %{session: session} do
    show = seed_show_with_backdrop()

    session
    |> login_as_admin()
    |> resize_window(1000, 800)
    |> visit("/media/#{show.id}")
    |> wait_for_liveview()

    [top, left, _height, _viewport, _page] = eval_js(session, @backdrop_metrics)

    assert top == 0, "backdrop top is #{top}, expected 0"

    assert left == 0,
           "backdrop left is #{left}, expected 0 because the drawer is closed below lg"

    # @sidebar_probe is deliberately not used here. Below lg the drawer is not
    # `drawer-open`, and daisyUI renders a closed `.drawer-side` as a hidden
    # `position: fixed` box spanning the whole viewport, so elementFromPoint can
    # never return one of its descendants and the probe cannot mean anything.
    # Assert the layer is genuinely fixed instead, which is what matters at this
    # width and what the wide test would otherwise be the only one covering.
    assert eval_js(session, @backdrop_position) == "fixed"
  end

  defp scroll_to_bottom(session) do
    eval_js(session, "window.scrollTo(0, document.body.scrollHeight); return 'ok';")
    session
  end

  defp seed_show_with_backdrop do
    tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Fixture Backdrop Show",
        year: 2015,
        tmdb_id: tmdb_id,
        metadata: %{poster_path: "/fixture-poster.jpg", backdrop_path: "/fixture-backdrop.jpg"}
      })

    # The image 404s in test because the path resolves to TMDB. That is fine and
    # deliberate: every assertion measures the container's rectangle, which is
    # set by `fixed inset-0` and does not depend on the image loading.

    # Twelve episodes plus eight timeline events put the page well past the
    # 800px viewport, which is what makes the height assertion meaningful.
    for n <- 1..12 do
      episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: n})
    end

    # Unwarmed, the recommendations load leaves the VM for the production
    # metadata relay during tests.
    warm_recommendations_cache(tmdb_id, :tv_show, [])

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
