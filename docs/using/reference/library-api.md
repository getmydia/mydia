# Library API

A GraphQL API for automating library management, separate from the [player API](api.md)
that the Mydia Player uses.

!!! warning "Beta"

    This API is in beta. Breaking changes are allowed and are announced in the release
    notes. Once it is declared stable, changes become additive and a removal is
    deprecated for one minor release first.

## Endpoint

```
POST /api/library/graphql
```

Requests need `Content-Type: application/json` and an `x-api-key` header. The
`api_key` query parameter is **not** accepted: query strings reach proxy and access
logs, and this endpoint can change your library.

The examples on this page read the key from `$LIBRARY_API_KEY` in your shell; set
it to a database key's value or to the `LIBRARY_API_KEY` environment variable's
value, whichever kind you're using.

```bash
curl -s http://localhost:4000/api/library/graphql \
  -H 'content-type: application/json' \
  -H "x-api-key: $LIBRARY_API_KEY" \
  -d '{"query": "{ qualityProfiles { id name } }"}'
```

## Authentication

Two kinds of key work.

### A database API key

Create one under **Configuration → API Keys**. Give it a name, an expiry (never,
30, 90 or 365 days) and the *Library API* scope, which is stored as the `admin`
permission. The owner must be an admin. The plain key is shown once, when you
create it; copy it then. Revoke or delete a key from the same page.

Keys created through the player API's `createApiKey` mutation also work, as
long as they carry the `admin` permission.

### `LIBRARY_API_KEY`

Set the environment variable and restart:

```bash
export LIBRARY_API_KEY="$(openssl rand -hex 32)"
```

This key is not a database row, so it is never accepted by the player API and does
not run an Argon2 verification on each request. Revoke it by removing the variable
and restarting. A value shorter than 32 characters is refused at boot.

See [Environment Variables](environment-variables.md) for the full entry.

## Queries

| Field | Returns |
| --- | --- |
| `lookup(query, type, year)` | Metadata-provider hits, each saying whether the library already has it |
| `mediaItem(id \| tmdbId \| tvdbId \| imdbId)` | One item with its availability status and episodes |
| `mediaItemChanges(first, after)` | A page of media item changes (live items and deletions), oldest revision first (see [Polling for changes](#polling-for-changes)) |
| `downloads(filter)` | The download queue and history |
| `events(first, after, types)` | Library activity, oldest first (see [Events](#events)) |
| `qualityProfiles` | Profiles available to assign |
| `libraryPaths` | Library paths available to add into |

Fetch the schema itself for the authoritative list:

```bash
curl -s http://localhost:4000/api/library/graphql \
  -H 'content-type: application/json' \
  -H "x-api-key: $LIBRARY_API_KEY" \
  -d '{"query": "{ __schema { queryType { fields { name } } } }"}'
```

There is no GraphiQL or Playground page on this endpoint. Use any GraphQL client
that can set a request header.

## Polling for changes

`mediaItemChanges` is the convergence feed: it reports every change to a media
item, deletions included, in the order the changes were recorded. A poller keeps
one cursor and never needs a timestamp.

```graphql
query Poll($after: String) {
  mediaItemChanges(first: 50, after: $after) {
    edges {
      cursor
      node {
        mediaItemId
        deleted
        changedAt
        mediaItem { id title updatedAt status { state } }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}
```

The first request omits `after` (or sends `null`). The feed then starts at the
oldest retained change and pages forward, so a full pass is an initial snapshot:
by the time `hasNextPage` is false you have seen the latest state of every item.
Keep `endCursor` and pass it as `after` on the next poll. An empty page repeats
the cursor you sent, so a poller that always passes back `endCursor` can never
fall back to the start of the feed.

Each edge is one change:

- `deleted: false` is a live item; `mediaItem` is the item's current
  representation. Upsert it into local state keyed by `mediaItemId`.
- `deleted: true` is a tombstone: `mediaItem` is `null` and `deleted` is true, so
  delete the local item named by `mediaItemId` (or ignore the change if you never
  had it). `mediaItemId` is present in both cases, which makes it the idempotency
  key and the deletion key: you never need to keep an earlier payload to act on
  a change.

```json
{
  "edges": [
    {"cursor": "djE6NA", "node": {"mediaItemId": "…", "deleted": true, "changedAt": "…", "mediaItem": null}}
  ]
}
```

Drain a response before sleeping: while `hasNextPage` is true there is another
page waiting behind the same cursor, so call again with the new `endCursor`
instead of waiting for the next poll interval.

```text
cursor = null
loop:
  page = mediaItemChanges(first: 50, after: cursor)   # omit after on the first call
  apply every edge: upsert node.mediaItem when deleted is false, delete node.mediaItemId when true
  cursor = page.pageInfo.endCursor
  repeat immediately while page.pageInfo.hasNextPage, else wait for the next poll
```

What the contract guarantees:

- **The cursor is the only synchronization watermark.** It is opaque and derived
  from an internal revision number, never from a timestamp. Do not parse it,
  compare it to `changedAt`, or build one yourself; pass `endCursor` back
  verbatim. A malformed cursor, and any cursor minted by the retired
  `mediaItems(updatedSince:)` feed, is refused with `INVALID_INPUT` instead of
  being ignored, so a stale client resyncs from scratch rather than resuming
  somewhere arbitrary.
- **Repeated delivery is safe and expected.** An item can appear on two pages, or
  change again while you are reading it, so one `mediaItemId` may arrive more than
  once, sometimes with the same state. Apply changes idempotently and treat
  omission (not repetition) as the only failure mode.
- **Tombstones are retained indefinitely.** This grows by one row per media item
  ever created, not per change, so a consumer that stops polling for months can
  still resume from its last cursor and see every deletion it missed.
- **`changedAt` is informational.** It is when the revision was recorded; for a
  live change it equals the node's `mediaItem.updatedAt`, which is the aggregate
  change time of the returned representation rather than only the parent row. Both
  are for display and for order-independent bookkeeping. Neither orders the feed
  and neither is a polling watermark. Note that `MediaItem.updatedAt` now reports
  the item's aggregate change time, which on upgrade is the migration instant for
  every existing item until it next changes.
- **Some availability changes have no database write behind them.** `status.state`
  compares episode air dates with the current UTC date, so a show can leave
  `UPCOMING` at a UTC date boundary with nothing written to the database. A
  sweep marks the affected shows and they arrive as ordinary live changes, a
  little after the boundary rather than at it. Expect a show to appear with no
  child write, and re-read the whole selection from every live change instead of
  merging only the fields you believe changed.
- **There is no push channel.** The endpoint answers requests only, so poll on the
  interval your consumers need; each page is a plain indexed read.

## Mutations

| Field | Does |
| --- | --- |
| `addMovie(input: {tmdbId, qualityProfileId, libraryPathId, monitored, searchNow})` | Adds a movie; `searchNow` queues an automatic search |
| `addTvShow(input: {tvdbId \| tmdbId, qualityProfileId, libraryPathId, monitored, seasonMonitoring, searchNow})` | Adds a show; `tvdbId` wins when both ids are given |
| `removeMediaItem(input: {id, deleteFiles})` | Removes an item, and its files when `deleteFiles` is true. `filesNotDeleted` counts files that could not be removed from disk |
| `setMediaItemMonitored(id, monitored)` | Monitoring for a movie or show |
| `setSeasonMonitored(mediaItemId, season, monitored)` | Monitoring for every episode of a season |
| `setEpisodeMonitored(id, monitored)` | Monitoring for one episode |
| `applyEpisodeMonitoring(mediaItemId, preset)` | `ALL`, `MISSING`, `EXISTING`, `FUTURE` or `NONE` |
| `searchMediaItem(id)` | Queues an automatic search for a movie or a whole show |
| `searchSeason(mediaItemId, season)` | Queues a search for one season, preferring a season pack |
| `searchEpisode(id)` | Queues a search for one episode |
| `cancelDownload(id)` | Removes a download from its client and the queue |
| `rejectRelease(id, blocklistDays)` | Removes a download, blocklists its release and searches again |

Each returns a payload with the thing it changed and a `userErrors` list. An
expected failure leaves the main field null and fills `userErrors`, each with a
`code`, a `message`, and the `field` path of the argument that caused it:

```json
{
  "data": {
    "addMovie": {
      "mediaItem": null,
      "userErrors": [
        {"field": ["input", "qualityProfileId"], "code": "INVALID_INPUT", "message": "Not a valid id"}
      ]
    }
  }
}
```

| Code | Meaning |
| --- | --- |
| `ALREADY_IN_LIBRARY` | The title is already there; `mediaItem` is the existing item |
| `NOT_FOUND` | An id names nothing |
| `INVALID_INPUT` | The arguments cannot be satisfied |
| `METADATA_UNAVAILABLE` | The metadata relay could not provide the title |
| `CLIENT_UNAVAILABLE` | `cancelDownload` only: the download client could not remove it, so the download is still queued |

`searchMediaItem`, `searchSeason` and `searchEpisode` report `queued: true` when
the job is inserted. A repeat within 60 seconds is merged into the first and
still reports `true`. `cancelDownload` and `rejectRelease` return `removedId`,
because both delete the download row. `rejectRelease` removes the item from its
client on a best-effort basis, as the Downloads page does.

## Events

`events` pages through library activity, oldest first:

```graphql
{ events(first: 100, after: "…") { edges { node { type occurredAt data } } pageInfo { endCursor } } }
```

Keep `endCursor` and pass it as `after` next time. On an empty page `endCursor`
repeats the `after` you sent, so you can always pass it back. `types` narrows
the feed to the types you name; by default you get every published type, and a
type outside that list is `INVALID_INPUT`. `data`'s keys depend on the type and
may change during beta.

The feed is best-effort activity history, not a convergence feed. Use it to learn
that something happened, then read `mediaItemChanges` or `downloads` for the
state. If what you need is the current state of the library, poll
`mediaItemChanges` and skip `events` entirely; the two use different cursors and
are not interchangeable.

- Events can be missing. Mydia drops events under heavy load and loses a batch
  whose write fails.
- An event appears about 35 seconds after it happens, a delay longer than the
  database's own write timeout, so an event written during a library scan still
  lands before the feed hands out a cursor past it.
- Events are kept for 90 days. A cursor older than that resumes at the oldest
  event left.

## Cost

- `downloads` contacts **every** configured download client on each call, so it is
  not paged and is the most expensive query here. For polling a library's changes
  prefer `mediaItemChanges`: it is a plain indexed read and contacts nothing.
- `mediaItemChanges` prices a page as `first` times the cost of the selection
  under `edges { node { … } }`, and the endpoint's complexity budget is 2000. What
  you select inside `node` therefore decides how large a page you can take. A page
  of `mediaItem { id title updatedAt status { state } }` costs 2200 at
  `first: 200` and is refused; the same selection costs 550 at the default
  `first: 50` and passes. Narrowing buys the page size back: `mediaItem { id }`
  costs 1400 at `first: 200`, and asking only for the change itself
  (`mediaItemId`, `deleted`, `changedAt`) costs 1000. So keep the default
  `first: 50`, lower `first`, or select fewer `mediaItem` fields when you need a
  larger page.
- `mediaItemChanges` takes `first` from 1 to 200 (default 50); a value outside
  that range is rejected with `INVALID_INPUT` rather than clamped to it. The
  complexity refusal is a separate GraphQL error: it names complexity rather than
  `INVALID_INPUT`, and it arrives before any query runs.
- A page holds one entry per changed item, so one poll page is one read however
  many items it carries; the cost is the price of the selected fields, not of the
  library.
- `addMovie` and `addTvShow` each ask the metadata relay for the title, and are
  priced like `lookup`.
- `events` takes `first` from 1 to 200 (default 100), priced like
  `mediaItemChanges`.

## Errors

Queries report expected failures as GraphQL errors carrying a code in
`extensions.code` (mutations use `userErrors`, above):

| Code | Meaning |
| --- | --- |
| `FORBIDDEN` | The key is valid but its role may not perform this operation |
| `INVALID_INPUT` | The arguments cannot be satisfied, e.g. two identifiers, or a broken cursor |
| `METADATA_UNAVAILABLE` | The metadata relay could not be reached |

HTTP-level failures are `401` for a missing or invalid key, `403` for a key without
the admin scope, and `429` when too many failed attempts come from one address.

## A key also authenticates on the player API

A database API key authenticates as its owner everywhere that owner can go,
including the player API. There, an API-key caller can create further keys and pair
devices, and those credentials keep working after the original key is revoked.
Treat a library API key like the owner's password.

`LIBRARY_API_KEY` does not have this problem: it is not a database row, so the
player API never accepts it.
