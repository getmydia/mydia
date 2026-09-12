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
| `mediaItems(first, after, updatedSince)` | A page of items, oldest change first (`updatedSince` is inclusive) |
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

The feed is best-effort. Use it to learn that something happened, then read
`mediaItems(updatedSince:)` or `downloads` for the state:

- Events can be missing. Mydia drops events under heavy load and loses a batch
  whose write fails.
- An event appears about 35 seconds after it happens, a delay longer than the
  database's own write timeout, so an event written during a library scan still
  lands before the feed hands out a cursor past it.
- Events are kept for 90 days. A cursor older than that resumes at the oldest
  event left.

## Cost

- `downloads` contacts **every** configured download client on each call, so it is
  not paged and is the most expensive query here. Prefer `mediaItems(updatedSince:)`
  for polling a library's changes.
- `updatedSince` is inclusive, so the item updated exactly at that instant comes
  back again on the next poll if you just advance `updatedSince` to its `updatedAt`.
  Keep the last page's `endCursor` and pass it as `after` on the next poll instead,
  or dedupe by `id` if you re-poll from the last seen `updatedAt`.
- `mediaItems` computes availability per item. `first` accepts 1 to 200; a value
  outside that range is rejected with `INVALID_INPUT` rather than clamped to it.
- `addMovie` and `addTvShow` each ask the metadata relay for the title, and are
  priced like `lookup`.
- `events` takes `first` from 1 to 200 (default 100), priced like `mediaItems`.

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
