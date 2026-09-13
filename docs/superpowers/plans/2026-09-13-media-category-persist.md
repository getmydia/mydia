# Media Category Persistence Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make manual category saves from the media item page persist `category` and `category_override`, record real old/new values in history, and stop emitting misleading success events on no-op writes.

**Architecture:** Route UI saves through `Media.update_category/3`, which already uses `MediaItem.category_changeset/3`. Extract shared `persist_and_audit_media_item/3` from `update_media_item/3` so category writes get the same audit path. Keep `MediaItem.changeset/2` unable to cast category fields.

**Tech Stack:** Elixir, Phoenix LiveView, Ecto, ExUnit, `./dev mix test`.

**Spec:** `docs/superpowers/specs/2026-09-13-media-category-persist-design.md`

## Global Constraints

- Run every command through `./dev`, never bare `mix`.
- Commit with `devenv shell -- git commit -F <msgfile>` if pre-commit hooks apply; confirm with `git show --stat`.
- Do not add `category` or `category_override` to `MediaItem.changeset/2`.
- Do not emit `media_item.updated` when the changeset has no actual field changes.
- Manual category saves must pass `actor_type: :user` and `actor_id: to_string(socket.assigns.current_user.id)`.
- Use invented titles in tests (e.g. "Cinder Lantern", "Harbor Lights"), never real film names.
- Never run `./dev mix precommit` from an agent; run only the focused test paths named in each task.
- Batch all test paths for a task into one `./dev mix test a.exs b.exs` call.

## Baseline

Before Task 1:

```bash
./dev mix test test/mydia/media_test.exs test/mydia_web/live/media_live/show/hero_picker_modals_test.exs
```

Record the passing count. Existing `update_category` tests in `media_test.exs` must keep passing.

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `lib/mydia/media.ex` | Media context | Extract `persist_and_audit_media_item/3`; extend `update_category/3` with audit opts; add `:category` and `:category_override` to `extract_meaningful_changes/2`; skip audit when `changes == %{}` |
| `lib/mydia_web/live/media_live/show/category_events.ex` | Category modal handlers | Call `Media.update_category/3` instead of `update_media_item/3`; pass user audit opts |
| `lib/mydia_web/live/media_live/show/modals.ex` | Category modal markup | Bind lock checkbox to `:category_override` |
| `test/mydia/media/category_update_test.exs` | Context regression tests | New file |
| `test/mydia_web/live/media_live/show/category_events_test.exs` | LiveView regression tests | New file |

No schema migrations. `lib/mydia/media/media_item.ex` unchanged.

---

### Task 1: Audited category persistence in context

**Files:**
- Modify: `lib/mydia/media.ex` (`update_media_item/3`, `update_category/3`, `extract_meaningful_changes/2`)
- Create: `test/mydia/media/category_update_test.exs`

**Interfaces:**
- Consumes: `MediaItem.category_changeset/3`, `Events.media_item_updated/5`
- Produces:
  ```elixir
  @spec update_category(MediaItem.t(), atom() | String.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  # opts: :override (bool, default false), :reason, :actor_type, :actor_id
  ```
  ```elixir
  defp persist_and_audit_media_item(changeset, original, opts) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  ```

- [ ] **Step 1: Write failing context tests**

Create `test/mydia/media/category_update_test.exs`:

```elixir
defmodule Mydia.Media.CategoryUpdateTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Events
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  describe "update_category/3 audit" do
    test "persists category and records old/new in history" do
      item = media_item_fixture(%{type: "movie"})
      assert item.category == "movie"

      assert {:ok, updated} =
               Media.update_category(item, :anime_movie,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert updated.category == "anime_movie"
      assert Repo.get!(MediaItem, item.id).category == "anime_movie"

      [event] =
        Events.list_events(
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: item.id
        )

      assert event.metadata["reason"] == "Category updated"
      assert event.metadata["changes"]["category"] == %{"old" => "movie", "new" => "anime_movie"}
    end

    test "persists category_override when override: true" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, updated} =
               Media.update_category(item, :cartoon_movie,
                 override: true,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert updated.category_override == true
      assert Repo.get!(MediaItem, item.id).category_override == true

      [event] =
        Events.list_events(
          type: "media_item.updated",
          resource_type: "media_item",
          resource_id: item.id
        )

      assert event.metadata["changes"]["category_override"] == %{"old" => false, "new" => true}
    end

    test "does not emit media_item.updated when nothing changed" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, _} =
               Media.update_category(item, :movie,
                 override: false,
                 reason: "Category updated",
                 actor_type: :user,
                 actor_id: "user-1"
               )

      assert Events.list_events(
               type: "media_item.updated",
               resource_type: "media_item",
               resource_id: item.id
             ) == []
    end

    test "update_media_item/3 cannot change category (boundary)" do
      item = media_item_fixture(%{type: "movie"})

      assert {:ok, updated} =
               Media.update_media_item(item, %{category: "anime_movie", category_override: true})

      assert updated.category == "movie"
      assert Repo.get!(MediaItem, item.id).category == "movie"
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./dev mix test test/mydia/media/category_update_test.exs
```

Expected: failures on missing history metadata, `category_override` audit, and/or no-op event suppression.

- [ ] **Step 3: Implement audited persistence**

In `lib/mydia/media.ex`:

1. Refactor `update_media_item/3` to delegate post-update work to a new private helper:

```elixir
defp persist_and_audit_media_item(changeset, original, opts) do
  case Repo.update(changeset) do
    {:ok, updated} ->
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")
      reason = Keyword.get(opts, :reason, "Updated")
      changes = extract_meaningful_changes(changeset, original)

      if changes != %{} do
        Events.media_item_updated(updated, actor_type, actor_id, reason, changes)
      end

      {:ok, updated}

    error ->
      error
  end
end
```

2. Change `update_media_item/3` body to:

```elixir
changeset = MediaItem.changeset(media_item, attrs)
persist_and_audit_media_item(changeset, media_item, opts)
```

3. Extend `update_category/3`:

```elixir
def update_category(%MediaItem{} = media_item, category, opts \\ []) do
  override = Keyword.get(opts, :override, false)
  audit_opts = Keyword.take(opts, [:reason, :actor_type, :actor_id])

  changeset = MediaItem.category_changeset(media_item, category, override: override)
  persist_and_audit_media_item(changeset, media_item, audit_opts)
end
```

4. Add `:category` and `:category_override` to the `Map.take` list in `extract_meaningful_changes/2`:

```elixir
|> Map.take([:title, :original_title, :year, :monitored, :monitor_new_seasons,
             :category, :category_override])
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
./dev mix test test/mydia/media/category_update_test.exs test/mydia/media_test.exs:994 test/mydia/media_test.exs:3539
```

Expected: all targeted tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/mydia/media.ex test/mydia/media/category_update_test.exs
git commit -m "fix(media): audit category updates through update_category/3"
```

---

### Task 2: Wire LiveView save and reset to update_category/3

**Files:**
- Modify: `lib/mydia_web/live/media_live/show/category_events.ex`
- Modify: `lib/mydia_web/live/media_live/show/modals.ex`

**Interfaces:**
- Consumes: `Media.update_category/3` from Task 1
- Produces: `save_category/2` and `reset_category_to_auto/2` that persist category changes

- [ ] **Step 1: Fix modal checkbox field name**

In `lib/mydia_web/live/media_live/show/modals.ex`, change:

```elixir
field={@category_form[:override]}
```

to:

```elixir
field={@category_form[:category_override]}
```

- [ ] **Step 2: Update save_category/2**

Replace the `Media.update_media_item/3` call in `save_category/2` with:

```elixir
category = params["category"]

override =
  case params["category_override"] do
    "true" -> true
    true -> true
    _ -> false
  end

case Media.update_category(media_item, category,
       override: override,
       reason: "Category updated",
       actor_type: :user,
       actor_id: to_string(socket.assigns.current_user.id)
     ) do
```

Remove the old line:

```elixir
params = Map.put(params, "category_override", params["override"] == "true")
```

- [ ] **Step 3: Update reset_category_to_auto/2**

Replace the `Media.update_media_item/3` call with:

```elixir
case Media.update_category(media_item, new_category,
       override: false,
       reason: "Category reset to auto-detected",
       actor_type: :user,
       actor_id: to_string(socket.assigns.current_user.id)
     ) do
```

- [ ] **Step 4: Compile check**

```bash
./dev mix compile --warnings-as-errors
```

Expected: clean compile.

- [ ] **Step 5: Commit**

```bash
git add lib/mydia_web/live/media_live/show/category_events.ex lib/mydia_web/live/media_live/show/modals.ex
git commit -m "fix(media): save category changes through update_category/3"
```

---

### Task 3: LiveView regression tests

**Files:**
- Create: `test/mydia_web/live/media_live/show/category_events_test.exs`

**Interfaces:**
- Consumes: wired `save_category/2`, `reset_category_to_auto/2`, modal form `#category-override-form`
- Produces: end-to-end proof that badge and DB state update

- [ ] **Step 1: Write failing LiveView tests**

Create `test/mydia_web/live/media_live/show/category_events_test.exs`:

```elixir
defmodule MydiaWeb.MediaLive.Show.CategoryEventsTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "saving a new category updates the badge and database", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Cinder Lantern", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("button[title='Click to change category']") |> render_click()
    assert has_element?(view, "#category-override-form")

    view
    |> form("#category-override-form", %{
      "media_item" => %{"category" => "anime_movie", "category_override" => "false"}
    })
    |> render_submit()

    refute has_element?(view, "#category-override-form")
    assert render(view) =~ "Anime"
    assert Repo.get!(MediaItem, item.id).category == "anime_movie"
  end

  test "locking category persists override and shows pencil icon", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Harbor Lights", year: 2024})

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("button[title='Click to change category']") |> render_click()

    view
    |> form("#category-override-form", %{
      "media_item" => %{"category" => "cartoon_movie", "category_override" => "true"}
    })
    |> render_submit()

    updated = Repo.get!(MediaItem, item.id)
    assert updated.category == "cartoon_movie"
    assert updated.category_override == true
    assert has_element?(view, ".hero-pencil-square")
  end

  test "reset to auto clears override", %{conn: conn} do
    item = media_item_fixture(%{type: "movie", title: "Tidepool Academy", year: 2024})
    {:ok, locked} = Mydia.Media.update_category(item, :cartoon_movie, override: true)

    {:ok, view, _html} = live(conn, ~p"/media/#{locked.id}")

    view |> element("button[title='Click to change category']") |> render_click()
    assert has_element?(view, "button", "Reset to Auto")

    view |> element("button", "Reset to Auto") |> render_click()

    updated = Repo.get!(MediaItem, item.id)
    assert updated.category_override == false
    refute has_element?(view, "#category-override-form")
  end
end
```

- [ ] **Step 2: Run tests**

```bash
./dev mix test test/mydia_web/live/media_live/show/category_events_test.exs
```

Expected: PASS after Task 2.

- [ ] **Step 3: Run full targeted suite**

```bash
./dev mix test test/mydia/media/category_update_test.exs test/mydia_web/live/media_live/show/category_events_test.exs
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/mydia_web/live/media_live/show/category_events_test.exs
git commit -m "test(media): cover category save and reset from item page"
```

---

## Verification

After all tasks:

```bash
./dev mix test test/mydia/media/category_update_test.exs test/mydia_web/live/media_live/show/category_events_test.exs test/mydia/media_test.exs:994 test/mydia/media_test.exs:3539
```

Manual smoke (optional):

1. Open a movie item page.
2. Change category via modal, save.
3. Confirm badge updates immediately and after reload.
4. Lock category, save, confirm pencil icon appears.
5. Reset to Auto, confirm override clears.
6. Check item history shows `category` / `category_override` old to new values.

## Out of Scope

- Routing batch reclassification through audited `update_category/3` (already persists; audit follow-up).
- Adding category fields to the general changeset.
- Fixing `update_quality_profile/2` reload pattern.
