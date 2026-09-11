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

```bash
curl -s http://localhost:4000/api/library/graphql \
  -H 'content-type: application/json' \
  -H "x-api-key: $MYDIA_LIBRARY_API_KEY" \
  -d '{"query": "{ qualityProfiles { id name } }"}'
```

## Authentication

Two kinds of key work.

### A database API key

There is no dedicated admin page for these yet; one is planned for a later
release. Until then, authenticate to `/api/graphql` as an admin user (a
browser session, a bearer access token, or an existing API key all work) and
call the player API's `createApiKey` mutation with `permissions: ["admin"]`.
The owning user must be an admin. The plain key is shown once, in the
mutation's response.

Alternatively, skip database keys entirely and set `LIBRARY_API_KEY` (below).

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
| `mediaItems(first, after, updatedSince)` | A page of items, oldest change first |
| `downloads(filter)` | The download queue and history |
| `qualityProfiles` | Profiles available to assign |
| `libraryPaths` | Library paths available to add into |

Fetch the schema itself for the authoritative list:

```bash
curl -s http://localhost:4000/api/library/graphql \
  -H 'content-type: application/json' \
  -H "x-api-key: $MYDIA_LIBRARY_API_KEY" \
  -d '{"query": "{ __schema { queryType { fields { name } } } }"}'
```

There is no GraphiQL or Playground page on this endpoint. Use any GraphQL client
that can set a request header.

## Cost

- `downloads` contacts **every** configured download client on each call, so it is
  not paged and is the most expensive query here. Prefer `mediaItems(updatedSince:)`
  for polling a library's changes.
- `mediaItems` computes availability per item. `first` accepts 1 to 200; a value
  outside that range is rejected with `INVALID_INPUT` rather than clamped to it.

## Errors

Expected failures come back as GraphQL errors carrying a code in
`extensions.code`:

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
