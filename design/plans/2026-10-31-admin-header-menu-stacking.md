# Admin Header Menu Stacking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the admin page header's action menus (Library Paths Export, #1317) clickable over their whole area by raising the header above the hub tab strip and page switcher.

**Architecture:** `admin_page/1` renders `#admin-page-header` then `#admin-page-tabs` (`relative z-10`) and `#admin-page-switcher` (`.dropdown z-20`). Header menus at `z-10` or lower lose to them. Giving `#admin-page-header` `relative z-[25]` makes it a stacking context above both and below the sticky mobile header (30). A Wallaby feature test hit-tests each menu item's centre.

**Tech Stack:** Phoenix LiveView, Tailwind v4 + daisyUI 5, Wallaby feature tests (`MydiaWeb.FeatureCase`).

Spec: `design/specs/2026-10-31-admin-header-menu-stacking-design.md`.

## Global Constraints

- Header z-index is exactly `z-[25]`: above tabs (10) and switcher (20), below sticky mobile header (30), sidebar (40), dock (50).
- Assert with `document.elementFromPoint`, never class presence.
- `:feature` tests are excluded by default; run with `./dev feature-test <path> --only feature` and confirm `Including tags: [:feature]` plus a non-zero test count.
- A fresh worktree needs assets built once before feature tests: `devenv shell -- bash -c 'mix assets.setup && mix assets.build'`. Rebuild after changing any class string.
- Commit from inside the devenv environment (`direnv exec . git commit ...`), never `--no-verify`; verify with `git show --stat`.
- No em dashes in prose.

---

### Task 1: Raise the admin page header above the hub tabs

**Files:**
- Create: `test/mydia_web/features/admin_header_menu_stacking_test.exs`
- Modify: `lib/mydia_web/components/admin_components.ex:157-160` (`#admin-page-header` class)
- Modify: `lib/mydia_web/components/README.md` (z-index table under "No card-level dropdown can win on z-index", about line 185)

**Interfaces:**
- Consumes: `MydiaWeb.FeatureCase` helpers `login_as_admin/1`, `resize_window/3`, `visit_liveview/2`, `eval_js/3`, `assert_has/2`, `Query.css/1` (all used in `test/mydia_web/features/media_file_menu_stacking_test.exs`).
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing test**

Create `test/mydia_web/features/admin_header_menu_stacking_test.exs`:

```elixir
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
```

- [ ] **Step 2: Build assets (once per worktree) and run the test to verify it fails**

Run:
```bash
devenv shell -- bash -c 'mix assets.setup && mix assets.build'
./dev feature-test test/mydia_web/features/admin_header_menu_stacking_test.exs --only feature
```
Expected: `Including tags: [:feature]`, 2 tests, both FAIL with a non-empty list naming `#library-export-json` and/or `#library-export-csv` covered by an element inside `#admin-page-tabs` (1440) or `#admin-page-switcher` (375).

The first draft of this plan used 1024 for the switcher case. Execution found the
test passing there: from `md` up the menu opens right-aligned and clears the
switcher, so the switcher only overlaps it on phones. 375 replaced it.

If either test passes, stop: the cause in the spec is wrong for that width. Report the actual hit elements instead of continuing.

- [ ] **Step 3: Implement the fix**

In `lib/mydia_web/components/admin_components.ex`, inside `admin_page/1`, change the header and add a comment above it:

```heex
    <%!-- relative z-[25] lifts header action menus (Export on Library Paths)
          over the tab strip (z-10) and the switcher (z-20) that follow it,
          while staying under the sticky mobile header (z-30). #1317 --%>
    <div
      id="admin-page-header"
      class="relative z-[25] flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6"
    >
```

Only the `admin_page/1` header changes; the `page_header/1` variant around line 115 stays as is.

- [ ] **Step 4: Rebuild assets and run the test to verify it passes**

Run:
```bash
devenv shell -- bash -c 'mix assets.build'
./dev feature-test test/mydia_web/features/admin_header_menu_stacking_test.exs --only feature
```
Expected: `Including tags: [:feature]`, 2 tests, 0 failures.

- [ ] **Step 5: Document the layer in the README**

In `lib/mydia_web/components/README.md`, add a row to the z-index table after "Card badges | 10":

```markdown
| Admin page header (`#admin-page-header`) | 25 |
```

and add this as a new paragraph right after the paragraph that ends "...so the test hit-tests the centre of each overlap instead." (just before the `## .menu is fit-content` heading):

```markdown
Menus in an admin page's `<:actions>` sit in `#admin-page-header`, which
`admin_page/1` lifts to `z-[25]` so they clear the hub tab strip (`z-10`) and the
page switcher (`z-20`) that follow it in the DOM. At `z-10` the strip took the
clicks across the middle of the Library Paths Export menu (#1317).
`test/mydia_web/features/admin_header_menu_stacking_test.exs` guards it.
```

- [ ] **Step 6: Run precommit**

Run: `./dev mix precommit`
Expected: exits 0. If it outruns the tool timeout, run `./dev mix format --check-formatted` and `./dev mix compile --warnings-as-errors` plus `./dev mix test test/mydia_web/live/admin_library_paths_live` instead, and note that in the report.

- [ ] **Step 7: Commit**

```bash
git add lib/mydia_web/components/admin_components.ex lib/mydia_web/components/README.md test/mydia_web/features/admin_header_menu_stacking_test.exs
direnv exec . git commit -m "fix(admin): lift header action menus above the hub tabs (#1317)"
git show --stat HEAD
git status --porcelain
```
Expected: the three files in the stat, and an empty `git status --porcelain`.
