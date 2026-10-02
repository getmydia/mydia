defmodule MydiaWeb.Features.SelectionToolbarDockTest do
  @moduledoc """
  The library's floating selection toolbar must stay reachable on a phone.

  Below Tailwind's `lg` breakpoint the mobile dock (`#mobile-dock`) is fixed to
  the bottom edge and paints over anything fixed beside it, and the toolbar
  with its "Select all N" button is wider than a 375px viewport unless it
  wraps. Neither can be seen from a server-rendered assertion, so this hit
  tests the real layout.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  setup do
    items =
      for title <- ["Harbor Lantern", "Quiet Orchard", "Paper Compass"] do
        insert(:media_item, type: "movie", title: title)
      end

    %{items: items}
  end

  # Hit tests the centre of `selector`. Returns "inside" when the topmost
  # element there belongs to the toolbar, otherwise a string naming the
  # problem, so a missing or collapsed target can never read as a pass.
  defp probe(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      if (!el) { return 'missing ' + arguments[0]; }
      var r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) { return 'zero-sized ' + arguments[0]; }
      var toolbar = document.getElementById('selection-toolbar');
      if (!toolbar) { return 'missing #selection-toolbar'; }
      var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
      if (!hit) { return 'off-screen ' + arguments[0]; }
      if (toolbar.contains(hit)) { return 'inside'; }
      return 'covered by ' + hit.tagName.toLowerCase() + (hit.id ? '#' + hit.id : '');
      """,
      [selector]
    )
  end

  test "every toolbar control fits a 375px phone and is not under the dock",
       %{session: session, items: [first | _]} do
    login_as_admin(session)

    session
    |> resize_window(375, 800)
    |> visit_liveview("/movies")
    |> js_click("#select-from-card-#{first.id}")
    |> assert_has(Query.css("#select-all-matching"))

    assert probe(session, "#select-all-matching") == "inside"
    assert probe(session, "#batch-auto-search-btn") == "inside"

    bounds =
      eval_js(session, """
      var toolbar = document.getElementById('selection-toolbar');
      if (!toolbar) { return '__missing__'; }
      var r = toolbar.getBoundingClientRect();
      return {left: r.left, right: r.right, width: document.documentElement.clientWidth};
      """)

    assert is_map(bounds), "expected #selection-toolbar to exist, got #{inspect(bounds)}"
    assert bounds["left"] >= 0, "toolbar overflows the left edge: #{inspect(bounds)}"
    assert bounds["right"] <= bounds["width"], "toolbar overflows the right: #{inspect(bounds)}"
  end
end
