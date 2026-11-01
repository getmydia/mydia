defmodule MydiaWeb.Features.AdminHeaderMenuStackingTest do
  @moduledoc """
  Menus in the admin page header paint above the hub tab strip and the page
  switcher that follow the header (#1317).

  The Library Paths Export menu was `z-10`, the same as `#admin-page-tabs`,
  which comes later in the DOM and won, so the strip took the clicks across
  the middle of the open menu. On phones the switcher (`z-20`) did the same.
  Only `elementFromPoint` over the open menu can see that.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  @items ["library-export-json", "library-export-csv", "library-export-files-csv"]

  # Opens the daisyUI focus dropdown, then returns, for each item whose centre
  # does not hit the item itself, the id and a description of what it hits.
  defp covered_items(session) do
    eval_js(
      session,
      """
      var trigger = document.getElementById('library-export-menu');
      if (!trigger) { return '__missing__'; }
      trigger.focus();

      function describe(node) {
        if (!node) { return 'null'; }
        var out = node.tagName.toLowerCase();
        if (node.id) { out += '#' + node.id; }
        return out;
      }

      var covered = [];
      var ids = arguments[0];
      for (var i = 0; i < ids.length; i++) {
        var item = document.getElementById(ids[i]);
        if (!item) { return '__missing__'; }
        var r = item.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) { return '__closed__'; }
        var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        if (hit !== item && !item.contains(hit)) {
          covered.push(ids[i] + ' -> ' + describe(hit));
        }
      }
      return covered;
      """,
      [@items]
    )
  end

  # 1440 shows the lifted tab strip (xl and up), which covered CSV. Below xl the
  # page switcher replaces it, but only below md does the menu open
  # left-aligned over it (it is `md:dropdown-end`), so 375 is the width where
  # the switcher covered JSON; at 768 and 1024 the menu clears it.
  for {width, height} <- [{1440, 900}, {375, 812}] do
    @tag :feature
    test "every Export menu item takes clicks at #{width}x#{height}", %{session: session} do
      login_as_admin(session)

      session
      |> resize_window(unquote(width), unquote(height))
      |> visit_liveview("/admin/library-paths")
      |> assert_has(Query.css("#library-export-menu"))

      assert covered_items(session) == []
    end
  end
end
