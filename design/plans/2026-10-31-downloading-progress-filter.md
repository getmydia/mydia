# Downloading Progress Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Downloading" option to the `/movies` and `/tv` progress filter so items with an active download can be filtered (#1252).

**Architecture:** Items already carry `AvailabilityStatus.state == :downloading`, and `LibraryListing.filter_progress/2` already filters on that state. Only the URL parameter map in `ListingParams` and the `<select>` in the template are missing the value.

**Tech Stack:** Phoenix LiveView, ExUnit, Gettext.

Spec: `design/specs/2026-10-31-downloading-progress-filter-design.md`

## Global Constraints

- Partial keeps its current meaning. Do not touch `AvailabilityStatus` or `LibraryListing`.
- UI text goes through `pgettext("library progress", ...)`, then `./dev mix gettext.extract` regenerates `priv/gettext/*.pot`. Never edit `.po` files.
- Run git from inside the devenv environment (direnv is allowed for this worktree). Stage everything before `git commit`, then check `git show --stat HEAD`.

---

### Task 1: Downloading progress filter

**Files:**
- Modify: `lib/mydia_web/live/media_live/index/listing_params.ex` (the `@progress` map and the `progress:` line of `@type t`)
- Modify: `lib/mydia_web/live/media_live/index.html.heex` (the `name="progress"` `<select>`, around line 214)
- Regenerate: `priv/gettext/default.pot`
- Test: `test/mydia_web/live/media_live/listing_params_test.exs`
- Test: `test/mydia_web/live/media_live/index_test.exs`

**Interfaces:**
- Produces: `ListingParams.parse(%{"progress" => "downloading"}, _)` returns `progress: :downloading`, and `to_query/1` emits `{"progress", "downloading"}`. Remembered filters are restored through `parse/2`, so this one round-trip covers them.

- [ ] **Step 1: Write the failing parse test**

In `test/mydia_web/live/media_live/listing_params_test.exs`, directly after the `"upcoming is a valid progress filter"` test, add:

```elixir
  test "downloading is a valid progress filter" do
    parsed = ListingParams.parse(%{"progress" => "downloading"}, [])

    assert parsed.progress == :downloading
    assert ListingParams.to_query(parsed) == [{"progress", "downloading"}]
  end
```

- [ ] **Step 2: Write the failing LiveView test**

In `test/mydia_web/live/media_live/index_test.exs`, at the end of the test `"progress filter excludes movies with an active download from missing"` (just before its closing `end`), add:

```elixir

      view
      |> element("form#library-filter-form")
      |> render_change(%{"progress" => "downloading"})

      assert has_element?(
               view,
               "#test-debug-info[data-progress-filter='downloading'][data-stream-count='1']"
             )

      assert has_element?(view, "#media_items-#{downloading_movie.id}")
```

Then rename the test to `"progress filter puts movies with an active download under downloading, not missing"`.

Rows render with the default stream DOM id, `media_items-<id>`, the same selector `library_filter_test.exs` uses.

- [ ] **Step 3: Run both tests to verify they fail**

Run: `./dev mix test test/mydia_web/live/media_live/listing_params_test.exs test/mydia_web/live/media_live/index_test.exs`
Expected: the new parse test fails with `progress` being `nil`. The LiveView test fails on `data-progress-filter='downloading'`, because the unknown value parses to `nil`.

- [ ] **Step 4: Implement**

In `listing_params.ex`:

```elixir
  @progress %{
    "missing" => :missing,
    "partial" => :partial,
    "downloading" => :downloading,
    "downloaded" => :downloaded,
    "upcoming" => :upcoming
  }
```

and in `@type t`:

```elixir
          progress: :missing | :partial | :downloading | :downloaded | :upcoming | nil,
```

In `index.html.heex`, between the Partial and Downloaded `<option>`s:

```heex
          <option value="downloading" selected={@filter_progress == :downloading}>
            {pgettext("library progress", "Downloading")}
          </option>
```

- [ ] **Step 5: Regenerate gettext templates**

Run: `./dev mix gettext.extract`
Expected: `priv/gettext/default.pot` gains a `msgctxt "library progress"` / `msgid "Downloading"` entry. `git diff --stat priv/gettext` should show only `.pot` changes.

- [ ] **Step 6: Run tests to verify they pass**

Run: `./dev mix test test/mydia_web/live/media_live/ test/mydia_web/untranslated_text_test.exs test/mydia/accounts/library_listing_preference_test.exs`
Expected: all pass.

- [ ] **Step 7: Precommit**

Run: `./dev mix precommit`. If it hits the 600s tool timeout, run `./dev mix format --check-formatted`, `./dev mix compile --warnings-as-errors`, and the step 6 tests separately.

- [ ] **Step 8: Commit**

```bash
git add lib/mydia_web/live/media_live/index/listing_params.ex \
        lib/mydia_web/live/media_live/index.html.heex \
        priv/gettext/default.pot \
        test/mydia_web/live/media_live/listing_params_test.exs \
        test/mydia_web/live/media_live/index_test.exs
git commit -m "feat(library): filter the listing by downloading progress (#1252)"
git show --stat HEAD
git status --porcelain
```

Expected: five files in the commit and nothing left modified.
