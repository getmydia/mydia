# Media Category Persistence Fix — Design

**Date:** 2026-09-13  
**Status:** Approved for implementation  
**Bug:** Changing a media item's category from the item page does not persist. History logs a successful "Category updated" action, but the category badge remains unchanged. Lock Category has no effect on save.

## Problem Statement

Users can open the category modal on a media item detail page, select a new category, optionally lock it, and click Save. The UI shows success, and the item history records a `media_item.updated` event with reason "Category updated". After closing the modal, the category badge on the item page is unchanged. Reloading the page also shows the old category.

The Lock Category checkbox does not affect the saved result. Reset to Auto similarly reports success without changing the displayed category.

## Root Cause

The save path uses the wrong persistence API.

`MydiaWeb.MediaLive.Show.CategoryEvents.save_category/2` and `reset_category_to_auto/2` call `Media.update_media_item/3` with `category` and `category_override` attributes. `MediaItem.changeset/2` — the changeset used by `update_media_item/3` — does **not** cast either field:

```elixir
|> cast(attrs, [
  :type, :title, :original_title, :year, :tmdb_id, :tvdb_id, :imdb_id,
  :metadata_source, :season_order, :metadata, :monitored, :monitor_new_seasons,
  :quality_profile_id, :library_path_id
])
```

Ecto therefore produces a valid no-op changeset. `Repo.update/1` returns `{:ok, unchanged_item}`. The LiveView assigns that struct back to `socket.assigns.media_item`, fires a success flash, and `update_media_item/3` still emits a history event — even though nothing changed in the database.

The domain already has the correct write path: `Media.update_category/3` uses `MediaItem.category_changeset/3`, which casts and validates `category` and `category_override`. It is used by batch reclassification but not by the manual UI save handlers.

### Secondary issue: form field name mismatch

The category modal binds the lock checkbox to `@category_form[:override]`, but `change_media_item_category/2` casts `:category_override`. `save_category/2` manually maps `params["override"]` to `"category_override"` on submit, but validation and initial checkbox state do not use the same field name. This can make the lock checkbox appear disconnected from the item's current state during editing.

## Goals

1. Manual category saves persist `category` and `category_override` to the database.
2. Reset to Auto persists the auto-classified category with `category_override: false`.
3. History records actual old/new values for `category` and `category_override`, not just a generic success reason with empty changes.
4. Generic `update_media_item/3` remains unable to mutate category fields (preserves the existing security boundary).
5. Add regression tests so this cannot silently break again.

## Non-Goals

- Changing auto-classification logic in `CategoryClassifier`.
- Adding `category` fields to the general `MediaItem.changeset/2`.
- Redesigning the category modal UI beyond fixing the lock checkbox field binding.
- Fixing unrelated `update_quality_profile/2` persistence (quality profile is in the general changeset and works).

## Recommended Approach

**Category-specific API with shared audit handling** (approach 1 from brainstorming).

Route all manual category writes through `Media.update_category/3`, extended to support audit options and shared persistence internals with `update_media_item/3`.

## Architecture

### Data flow (after fix)

```
Category modal (phx-submit save_category)
  -> CategoryEvents.save_category/2
      -> Authorization.authorize_update_media/1
      -> normalize params (category, category_override from lock checkbox)
      -> Media.update_category/3(item, category, override: bool, reason: ..., actor_*: ...)
          -> MediaItem.category_changeset/3
          -> persist_and_audit_media_item/3  (private helper)
              -> Repo.update/1
              -> extract_meaningful_changes/2  (includes category fields)
              -> Events.media_item_updated/5
  -> assign updated %MediaItem{} to socket
  -> category badge re-renders with new value
```

Reset to Auto follows the same path, classifying first via `CategoryClassifier.classify/1`, then calling `update_category/3` with `override: false`.

### Components to change

| Layer | File | Change |
|-------|------|--------|
| Context | `lib/mydia/media.ex` | Extract `persist_and_audit_media_item/3` from `update_media_item/3`. Extend `update_category/3` to accept audit opts (`:reason`, `:actor_type`, `:actor_id`) and call the helper. Include `:category` and `:category_override` in `extract_meaningful_changes/2`. Route `reclassify_all_media_items/0` and `reclassify_media_items/2` through audited `update_category/3` for consistency. |
| Schema | `lib/mydia/media/media_item.ex` | No schema changes. `category_changeset/3` already correct. |
| LiveView events | `lib/mydia_web/live/media_live/show/category_events.ex` | Replace `Media.update_media_item/3` calls with `Media.update_category/3` in `save_category/2` and `reset_category_to_auto/2`. Pass user actor info from socket where available. |
| Modal form | `lib/mydia_web/live/media_live/show/modals.ex` | Rename lock checkbox field from `:override` to `:category_override` so it aligns with the changeset. Remove manual `override` to `category_override` mapping in `save_category/2`. |

### What stays unchanged

- `MediaItem.changeset/2` does not gain category fields.
- `change_media_item_category/2` remains the form/validation changeset for the modal.
- Category badge rendering in `components.ex` already reads `@media_item.category` and `@media_item.category_override`.

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Unauthorized user | `Authorization.authorize_update_media/1` returns `{:unauthorized, socket}`; no DB write, no flash. Existing behavior preserved. |
| Invalid category value | `category_changeset/3` validation fails; modal stays open with changeset errors on the select field. |
| Same category, same lock state | `Repo.update/1` returns `{:ok, item}` with empty changeset changes. Do not emit a misleading history event when `changes == %{}`. |
| Reset to Auto when already auto | Classifier may return the same category; if no fields change, no history event. Flash can still confirm current state. |
| DB error | `{:error, changeset}` returned to LiveView; modal stays open, error flash on reset path (existing pattern). |

## History / Audit Detail

When category fields change, `extract_meaningful_changes/2` must include:

```elixir
|> Map.take([:title, :original_title, :year, :monitored, :monitor_new_seasons,
             :category, :category_override])
```

Manual saves should pass:

- `reason: "Category updated"` or `"Category reset to auto-detected"`
- `actor_type: :user`
- `actor_id: socket.assigns.current_user.id` (when available)

## Testing

### 1. Context unit test — `test/mydia/media/category_update_test.exs` (new)

| Test | Assertion |
|------|-----------|
| `update_category/3` persists category | Item reloaded from DB has new `category` |
| `update_category/3` with `override: true` | `category_override` is true in DB |
| `update_category/3` emits history with changes | Event metadata contains `category` old/new |
| `update_category/3` with no actual change | No `media_item.updated` event emitted |
| `update_media_item/3` with category attrs | Category **not** changed (boundary test) |

### 2. LiveView integration test — `test/mydia_web/live/media_live/show/category_events_test.exs` (new)

Follow patterns from `show_library_test.exs` (`async: false`, `register_and_log_in_user`).

| Test | Assertion |
|------|-----------|
| Save category from modal | Badge text updates without page reload |
| Lock category and save | `category_override` true after save; badge shows override indicator |
| Reset to Auto | Category updates to classifier result; override cleared |

### Test command

```bash
./dev mix test test/mydia/media/category_update_test.exs test/mydia_web/live/media_live/show/category_events_test.exs
```

## Implementation Notes

1. Extract `persist_and_audit_media_item/3` from `update_media_item/3` and reuse in `update_category/3`.
2. Extend `update_category/3` to accept `:reason`, `:actor_type`, and `:actor_id` opts.
3. Align modal checkbox field to `:category_override`.
4. Do not reload after save unless associations require it; assigning the returned struct is sufficient.

## Success Criteria

- Changing category in the modal updates the badge immediately and after page reload
- Lock Category persists and is reflected in the badge override indicator
- Reset to Auto changes category and clears override
- History shows actual `category` / `category_override` old to new values
- No history event when save produces no actual DB change
- New tests pass on SQLite test adapter
