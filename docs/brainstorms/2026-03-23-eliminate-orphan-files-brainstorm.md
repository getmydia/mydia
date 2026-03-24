# Eliminate Orphan Media Files

**Date:** 2026-03-23
**Status:** Ready for planning

## What We're Building

Enforce at the database level that every `MediaFile` always belongs to a `MediaItem`. Currently, files can exist with no parent at all (both `media_item_id` and `episode_id` NULL), creating orphan records that are invisible in the UI and waste space.

### The Problem (Production Data)

Analysis of the production database (1797 files total):

| Category | Count | Issue |
|---|---|---|
| Episode-only (no `media_item_id`) | 1061 | Parent reachable only indirectly through `episode.media_item_id` |
| Media-item only (no `episode_id`) | 517 | 425 movies (correct), 92 TV shows (unmatched episodes) |
| Both parents set | **0** | Schema allows it, but it never happens |
| Both NULL (true orphans) | 219 | 218 trashed, 1 active — should be impossible |

The root cause: the schema treats `media_item_id` and `episode_id` as interchangeable optional FKs, but they serve different roles. `media_item_id` is the ownership link; `episode_id` is a refinement.

## Why This Approach

**Make `media_item_id` NOT NULL on `media_files`.**

- Every file MUST belong to a media item (movie or TV show)
- `episode_id` remains optional — it's a secondary link for TV show files that refines which episode the file belongs to
- This is the simplest change that eliminates all orphan categories at the DB level
- CASCADE delete on `media_item_id` stays — deleting a media item deletes its files
- NILIFY on `episode_id` stays — deleting an episode just clears the episode link, file remains under the media item

### Why not "require at least one parent" (CHECK constraint)?

- Doesn't solve the real problem: episode-only files are fragile (episode deletion orphans them)
- A CHECK constraint is weaker than a NOT NULL + FK — it can't enforce referential integrity

### Why not a staging table for unmatched files?

- Adds schema complexity for a rare edge case
- The scanner should be able to resolve the media item before inserting — it already parses filenames for this purpose

## Key Decisions

1. **`media_item_id` becomes NOT NULL** on the `media_files` table
2. **Scanner must resolve media item before insert** — if it can't determine the parent, skip the file and log a warning (no `scan_changeset` with NULL parents)
3. **Backfill migration**: set `media_item_id` from `episode.media_item_id` for the 1061 episode-only files
4. **True orphans**: delete records where both parents are NULL (these are overwhelmingly trashed files with no recovery path)
5. **CASCADE behavior unchanged**: deleting a media item cascades to its files, deleting an episode nilifies `episode_id`
6. **Both parents can be set simultaneously**: a TV show file should have `media_item_id` (always) AND `episode_id` (when matched)

## Existing Orphan Infrastructure (to simplify/remove)

The codebase already has extensive orphan-handling code that treats symptoms rather than the root cause. With `media_item_id` NOT NULL, much of this becomes dead code:

| Module | What it does | After this change |
|---|---|---|
| `DatabaseHealthCheck` | Startup check counting orphaned files, triggers rescan | `count_orphaned_files/0` becomes impossible — simplify or remove |
| Library scanner cleanup (lines 755-926) | Re-enriches orphaned files, fixes TV orphans on every scan | "Completely orphaned" branch eliminated; TV orphan fix simplified |
| `Library.list_orphaned_media_files/1` | Queries for orphans | Remove — query will always return empty |
| `Library.orphaned_media_file?/1` | Checks if file is orphaned | Remove |
| Import page orphan handling | Detects/re-matches orphaned files during import | Simplify — no orphans to re-match |
| `scan_changeset/2` | Allows NULL parents during scanning | Update to require `media_item_id` |
| `music_scanner.ex` `create_orphaned_music_file/1` | Creates music files with no parent | Update or remove |
| Config keys `:orphaned_files_fixed`, `:tv_orphans_fixed` | Track cleanup stats | Remove if cleanup code is removed |

## Scope

### In Scope

- Migration to backfill `media_item_id` and add NOT NULL constraint
- Update `MediaFile` schema/changeset to require `media_item_id`
- Remove `scan_changeset` or update it to require `media_item_id`
- Update scanner/file creation code to always provide `media_item_id`
- Update any code that creates files with episode-only linkage
- Remove or simplify orphan-handling infrastructure that becomes unnecessary

### Out of Scope

- Changing the scanner's file-matching algorithm
- UI changes (no new screens needed)
- Changing how trashing/soft-delete works
- Modifying the episode cascade behavior (already fixed in recent migration)
