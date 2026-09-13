# Library API Revision Polling

**Date:** 2026-09-12
**Status:** Approved design, ready for implementation planning

## Problem

The Library API currently presents `mediaItems(first, after, updatedSince)` as an incremental state feed. It orders and filters only by `media_items.updated_at`, while the returned `MediaItem` also contains episode state, file-derived ownership, active-download state, quality-profile data, and aggregate availability.

Those values can change without touching the parent row. Episode monitoring is the clearest example: `setEpisodeMonitored`, `setSeasonMonitored`, and `applyEpisodeMonitoring` update `episodes` while the `media_items` cursor remains unchanged. File import/trash/link changes, download completion or failure, episode metadata updates, and quality-profile renames have the same shape. A client can therefore advance past an item and never receive its changed representation.

The existing Simkl plugin records the same invariant in `plugins/simkl_sync/src/lib.rs`: it deliberately performs a full `library_item` scan because attaching a file does not necessarily advance `media_items.updated_at`.

The current `(updated_at, id)` cursor has a separate race. `updated_at` has second precision. A lower UUID can be updated into the cursor's second after a client has advanced beyond that UUID, placing the update permanently behind the cursor.

Deletion is also not a reliable state transition. A deleted row cannot appear in `mediaItems`, while the events feed is explicitly best-effort and may drop events.

## Goal

Provide a reliable, forward-only Library API feed from which an external consumer can converge to the latest library state.

The feed must:

- advance whenever the serialized `MediaItem` representation can change;
- use a database-generated monotonic order rather than wall-clock ordering;
- report deletions as durable tombstones;
- coalesce repeated changes to the latest state for each media item;
- cover writes from the UI, jobs, contexts, bulk SQL, cascades, and future callers;
- work on both SQLite and PostgreSQL;
- catch up clock-only availability changes after downtime;
- permit a clean beta break of the existing cursor contract.

Consumers do not need every intermediate transition. The separate `events` query remains the activity-history surface.

## Non-goals

- Turning `events` into a durable event log.
- Preserving existing `mediaItems` cursors or the `updatedSince` argument.
- Preserving every intermediate state transition.
- Changing the plugin `data-list` contract or `Mydia.Media.list_items_page/1`.
- Adding subscriptions or push delivery.
- Expiring tombstones or forcing old consumers through a resync window.
- Reporting file-analysis progress or download byte counters that do not affect the Library API `MediaItem` representation.

## Decisions

| Question | Decision |
| --- | --- |
| Compatibility | The API is beta; make a clean breaking cutover |
| Ordering source | Database-generated monotonic integer revision |
| Storage shape | One current revision row per media-item UUID |
| Write coverage | Adapter-specific database triggers |
| Deletions | Retain tombstones indefinitely |
| History semantics | Latest converged state only; intermediate changes coalesce |
| Public query | Replace `mediaItems` with `mediaItemChanges` |
| Timestamp | `changedAt` is informational and never orders pagination |
| Clock-derived status | Persistent UTC-day sweep at startup and after date changes |
| Existing plugin query | Leave `Mydia.Media.list_items_page/1` unchanged |

## Rejected approaches

### Application write hooks

A shared Elixir helper could mark an item after each context write. This is simpler SQL, but it cannot support the reliability claim. Current relevant writes span `Mydia.Media`, `Mydia.Library`, `Mydia.Downloads`, import promotion, join-table maintenance, changeset writes, `Repo.update_all`, `Repo.delete_all`, and raw SQL. Every future writer would also have to remember the helper. One omitted call silently recreates the original bug.

### Durable event pipeline

The event writer could become transactional and drive revisions. That would require removing its overload-drop behavior, changing retention, filling catalog gaps, and instrumenting every observable child write. It is substantially larger than the polling fix and still needs the same write-coverage audit. Activity history and state convergence remain separate responsibilities.

## Data model

### `media_item_revisions`

A new table stores the latest aggregate revision for every media-item UUID ever observed.

| Column | Type | Constraints and meaning |
| --- | --- | --- |
| `revision` | adapter-native monotonic 64-bit integer | Primary key; changes on every upsert |
| `media_item_id` | binary UUID | Unique; intentionally no foreign key |
| `deleted` | boolean | `false` for a live item, `true` for a tombstone |
| `changed_at` | `utc_datetime_usec` | Informational time of the latest revision |

There is no foreign key from `media_item_id` to `media_items`. A foreign key would either delete the marker or block parent deletion, defeating tombstones.

PostgreSQL uses an identity/sequence-backed `bigint`. SQLite uses `INTEGER PRIMARY KEY AUTOINCREMENT`. A trigger performs an insert with an omitted revision and upserts on `media_item_id`. Both adapters allocate the attempted insert's next revision before resolving the unique conflict, so the conflict update can replace the old revision with the new one. The SQLite behavior was verified against the repository runtime: a second upsert of one item advanced its revision from 1 to 2.

The conflict update applies only when the incoming revision is greater than the stored revision. PostgreSQL sequences allocate outside transaction commit order; without this condition, a delayed transaction holding revision 10 could overwrite revision 11 after the latter commits. The greater-than guard makes the marker monotonic under either commit order.

A migration backfills one live marker for every existing `media_items` row. It then installs triggers before the migration commits, leaving no uncovered write window.

Tombstones are retained indefinitely. This grows by one row per UUID ever used, not per change. Media-library item churn is low enough that indefinite resumability is preferable to cursor expiry and a resync protocol.

### `library_revision_clock`

A singleton table stores `last_processed_date` as a UTC `date`. Migration initializes it to the current UTC date after the media-item backfill, because that backfill already represents all prior state.

The watermark update and all revisions created by one clock sweep occur in the same transaction. Rollback leaves both unchanged so the next run retries the same interval.

## Revision ownership

Every trigger resolves a changed row to one or more owning media-item IDs.

- A media item owns itself.
- An episode belongs directly to `episodes.media_item_id`.
- A media file belongs through `media_files.media_item_id`, its primary `episode_id`, and every `media_file_episodes` link. Owner IDs are deduplicated before marking.
- A download belongs through `downloads.media_item_id` or its episode's media item.
- A quality profile change belongs to every media item referencing that profile.

An update that moves a child marks both the old and new owners. This applies to changes in parent IDs, episode IDs, and file/episode links.

Child-trigger upserts select owners through a still-live `media_items` row. This
prevents a cascading child delete from resurrecting the marker of a parent that
the same statement is deleting.

## Trigger coverage

Triggers advance revisions only for writes that can affect the current Library API representation.

### `media_items`

Insert and every update are observable and write `deleted: false`. Delete writes
`deleted: true`.

The parent delete trigger writes its tombstone from `OLD.id`. Child cascade
triggers cannot overwrite it with a live marker because their owner selection
requires the parent row still to exist; the greater-revision conflict guard is
the second line of defence.

### `episodes`

Insert and delete are observable because the API returns the episode collection and derives TV availability from it. Updates to the following fields are observable:

- `media_item_id`
- `season_number`
- `episode_number`
- `title`
- `air_date`
- `monitored`

Provider identity and metadata fields are included if they can alter a serialized episode field in the same write path. `last_upgrade_check_at` alone is excluded.

### `media_files`

Insert and delete are observable when the row is, or was, an active non-extra version owned by a movie or episode. Updates are observable when they change:

- `media_item_id`
- `episode_id`
- `trashed_at`
- `extra_kind`

Pure analysis fields such as codec probes, fingerprints, segment state, generated preview blobs, and analysis counters do not alter `MediaItem`, `Episode.hasFile`, or `AvailabilityStatus`; they do not advance the revision.

### `media_file_episodes`

Insert and delete are observable. `Episode.hasFile` reads the many-to-many association, so changing this join can change several episode representations even when `media_files.episode_id` remains fixed.

### `downloads`

Insert and delete are observable. Updates are observable when they change:

- `media_item_id`
- `episode_id`
- `completed_at`
- `error_message`

These are the ownership and active-state inputs used by `Mydia.Media.get_media_status/1` and `download_active?/1`. Download byte counters, client observation timestamps, retry counters, and similar progress bookkeeping do not advance a media-item revision unless the serialized availability status begins depending on them later.

### `quality_profiles`

A name update marks every referencing media item because `MediaItem.qualityProfile` exposes the name. Assignment changes already update `media_items` and are covered there. A delete marks referencing items before any association is removed or rejected by its constraint.

### Future fields

The observable dependency list is an explicit contract. Adding a field to `MediaItemView.item_map/2` or `episode_map/1`, or changing `get_media_status/1`, requires checking whether another column or table must advance revisions. A focused invariant test keeps the projection and declared dependency catalog aligned; it must assert consumer-visible behavior rather than compare trigger source text.

## Clock-derived changes

`Mydia.Media.get_media_status/1` compares episode `air_date` with `Date.utc_today/0`. A show can therefore leave `UPCOMING` at a UTC date boundary without a database write. Database triggers cannot observe this transition.

A clock sweep closes the gap:

1. A startup task runs after `Ecto.Migrator` and before `MydiaWeb.Endpoint`.
2. It locks the singleton clock row and reads `last_processed_date`.
3. It marks each show having an episode with `air_date` in `(last_processed_date, Date.utc_today()]`.
4. It updates the watermark to today in the same transaction.
5. An Oban cron job invokes the same operation after each UTC date change.

The interval handles multiple days of downtime. The query may conservatively mark a show whose aggregate status does not ultimately change; false-positive delivery is safe, while a missed transition is not. The watermark makes reruns idempotent.

Startup catch-up fails application boot if it cannot complete. The endpoint must not advertise a reliable feed while the persisted clock state is known stale. The recurring Oban job uses normal retries; a failure delays that day's clock-only updates but does not affect trigger-driven revisions.

## GraphQL contract

Replace the timestamp-based polling field with an explicit change feed:

```graphql
type Query {
  mediaItemChanges(first: Int = 50, after: String): MediaItemChangeConnection!
}

type MediaItemChange {
  mediaItemId: ID!
  deleted: Boolean!
  changedAt: DateTime!
  mediaItem: MediaItem
}
```

`MediaItemChangeConnection` uses the existing `PageInfo` shape. Each edge has a non-null `MediaItemChange` node and an opaque cursor.

- Live marker: `deleted: false`, `mediaItem` is the current hydrated representation.
- Tombstone: `deleted: true`, `mediaItem: null`.
- `mediaItemId` is always present so consumers can delete local state without retaining an earlier object.
- `first` retains the existing range of 1 through 200.
- Omitting `after` starts from the oldest retained marker and yields an initial snapshot.
- An empty page repeats the supplied cursor.

The cursor is a base64url encoding of a versioned revision payload, for example `v1:<revision>`. It does not contain a timestamp or UUID tie-breaker. Missing, malformed, wrong-version, negative, zero, or non-integer revision payloads return `INVALID_INPUT`.

`updatedSince` is removed. A wall-clock lower bound cannot provide the advertised guarantee, and retaining it beside revision ordering would create two conflicting watermark models.

`MediaItem.updatedAt` is sourced from the aggregate marker's `changed_at`, not `media_items.updated_at`. It therefore describes the returned representation rather than only the parent row. The parent timestamp remains unchanged internally for existing application and plugin behavior.

The committed SDL at `priv/graphql/library.graphql`, its drift test, API documentation, and complexity accounting change with the query. The API is beta, so there is no deprecated alias or old-cursor decoder. A changelog entry identifies the breaking replacement.

## Query and hydration flow

A dedicated `Mydia.LibraryApi` query pages `media_item_revisions` in ascending revision order. `Mydia.Media.list_items_page/1` remains untouched for plugin callers.

For each page:

1. Read `first + 1` revision markers strictly after the decoded revision.
2. Split the extra row to calculate `hasNextPage`.
3. Batch-load and preload all live media-item IDs using `MediaItemView.preloads/0`.
4. Build one change node per boundary marker.
5. Source edge cursors and `endCursor` from the revision markers, never hydrated rows.

Concurrent behavior is convergent:

- If an item changes after its boundary marker is read, hydration may return the newer state under the older cursor. The marker has also moved to a newer revision, so the item safely appears again.
- If an item is deleted between the boundary query and hydration, the missing hydration becomes a tombstone instead of dropping the edge. The later delete revision may repeat the tombstone.
- If an unprocessed marker moves forward while a client pages, it remains strictly after the client's cursor and cannot be skipped.
- Repeated delivery is expected and idempotent by `mediaItemId`; omission is not.

## Error handling and invariants

- Trigger changes participate in the source transaction. A rolled-back business write cannot leak a revision.
- Adapter-specific trigger SQL is isolated behind the migration and migration helper modules. Runtime query code is adapter-agnostic.
- A live `media_items` row without a revision marker is an internal invariant violation. Log it and return a top-level internal GraphQL error; do not fabricate a timestamp cursor or silently omit the item.
- A tombstone does not attempt hydration.
- A failed clock sweep does not advance its watermark.
- The `events` feed remains best-effort and is documented as activity history, not the source of truth for convergence.

## Testing

Tests prove observable contracts on both SQLite and PostgreSQL.

### Revision behavior

- Migration backfill gives every existing item one live marker.
- Parent insert/update advances a live marker.
- Episode monitoring and episode metadata changes advance the owning show.
- A file insert, active/trashed transition, extra/version transition, and many-to-many link change advance the correct owner.
- Active-download insertion, completion, failure, deletion, and re-parenting advance the correct owner; byte-only progress does not.
- A quality-profile rename advances every referencing item.
- Re-parenting marks both old and new owners.
- Several changes to one item leave one marker carrying the greatest revision.
- A rolled-back transaction leaves the prior marker unchanged.
- Parent deletion leaves a durable tombstone after cascades.

### Pagination behavior

- Initial paging returns every live item.
- A saved cursor sees a later child-only change.
- A lower UUID changed after cursor advancement cannot fall behind the cursor.
- Empty pages preserve the supplied cursor.
- Malformed and old timestamp cursors return `INVALID_INPUT`.
- Deletion after a saved cursor returns a tombstone.
- Hydration racing with deletion returns a tombstone and advances the true boundary.

### Clock behavior

- Catch-up across multiple offline dates marks shows with crossed air dates.
- Repeating a sweep on the same date is a no-op.
- A transaction failure leaves the date watermark unchanged.
- Startup ordering places catch-up after migrations and before the endpoint.

### Adapter and concurrency behavior

Run the same revision and GraphQL contract tests against SQLite and PostgreSQL. PostgreSQL additionally exercises two transactions that allocate revisions out of commit order and proves the stored marker never regresses.

### End-to-end smoke scenario

Exercise the actual GraphQL endpoint:

1. Read an initial `mediaItemChanges` page and retain `endCursor`.
2. Change episode monitoring without touching `media_items`.
3. Poll after the cursor and observe the updated live item.
4. Delete the item through the normal context path.
5. Poll again and observe its tombstone.

Finish with the focused Library API and migration suites, SDL drift check, PostgreSQL parity checks, and `./dev mix precommit`.

## Documentation

Update `docs/using/reference/library-api.md` to:

- replace `mediaItems(updatedSince:)` examples with `mediaItemChanges(after:)`;
- define live changes, tombstones, indefinite retention, and idempotent repeated delivery;
- state that the opaque cursor is the only synchronization watermark;
- explain that `changedAt` is informational;
- describe clock-only changes as eventually delivered after the UTC-day sweep;
- keep `events` positioned as best-effort activity history.

Add a changelog entry stating that the beta `mediaItems` timestamp cursor was replaced and old cursors are invalid.

## Scope boundary

This change necessarily updates existing media, library, download, migration, schema, documentation, and application-startup surfaces. The original Library API's additive-only implementation constraint cannot coexist with a database-wide observable-state guarantee. Changes remain limited to revision correctness: no unrelated media behavior, event durability, plugin polling, or player schema work is included.
