# Capabilities

A capability is a permission a plugin declares in the `capabilities` object of
its [manifest](manifest.md) and the operator grants. Capabilities are
deny-by-default and checked by the host on every call. A plugin cannot widen
its own grant.

Host functions named below are described in the [host API reference](host-api.md).

## Grants and approval

- A manifest only declares what a plugin wants. The grant is stored separately.
- A plugin installed from an index or remote package needs the operator to
  approve its declared capabilities. A revised manifest never widens an
  existing grant: a new class, a new value in a list (a hostname, an event, a
  namespace, a write surface) or a changed payload is a new request that stays
  denied until an administrator re-approves it in **Admin > System > Plugins**.
  Until then the plugin keeps running on the older grant and calls into the
  newly requested thing return `denied`.
- A value dropped from a manifest is not a request. The operator keeps the
  broader grant until they revoke it.
- A plugin bundled in Mydia's `priv/plugins/` directory is granted its declared
  set on discovery, and later releases replace the grant with the shipped
  manifest's capabilities.
- A manifest must declare at least one capability, and at least one of
  `events:subscribe`, `surfaces:page` or `surfaces:shelf`. A class the host does
  not know is rejected with `unknown capability class`.

<!-- source: lib/mydia/plugins/capabilities.ex:1-47; lib/mydia/plugins/manifest.ex:411-461; lib/mydia/plugins/host_functions.ex:1614-1660 -->

## Capability classes

"Flag" classes take an empty list. "List" classes take a list of values, and the
host checks each value, not just the class.

| Class | Takes | Grants | Host functions it unlocks |
|-------|-------|--------|---------------------------|
| [`events:subscribe`](#eventssubscribe) | List of event names | Delivery of the named [events](events.md) to `on-event`. | none |
| [`net:http`](#nethttp) | List of exact hostnames | Outbound HTTP to those hosts. | `http-request`; with `users:connections`, `link-request` and `connection-request` |
| [`data:read`](#dataread) | List of namespaces | Curated, read-only projections of Mydia data. | `data-read`, `data-list` |
| [`data:search`](#datasearch) | Flag | Searching the library and the metadata catalog from a page. | `search` |
| [`surfaces:write`](#surfaceswrite) | List of write surfaces | Curated writes. | `ensure-watched`, `set-watch-state`, `ensure-favorite`, `mark-watched-state`, `add-favorite`, `media-add`, `collection-*` |
| [`surfaces:page`](#surfacespage) | Flag | The plugin serves its own page. | the `page.on-http` export |
| [`surfaces:shelf`](#surfacesshelf) | Flag | The plugin fills Home shelves. | the `fill-shelf` export |
| [`state:kv`](#statekv) | Flag | A per-instance key/value store. | `kv-get`, `kv-set`, `kv-delete`, `kv-list`, `kv-set-many` |
| [`users:connections`](#usersconnections) | Flag | Per-user account links the host holds credentials for. | `connections-list`, `links-list`, `link-request`, `connection-request`, `propose-accounts`, `set-link-token`, `set-link-status` |
| [`schedule:interval`](#scheduleinterval) | Flag | Running `on-schedule` on a fixed interval. | the `on-schedule` export |

Two host functions need no capability: `log` and `report-sync-run`. `ensure-watched`,
`set-watch-state` and `ensure-favorite` also need an active connection to the target user.

<!-- source: lib/mydia/plugins/manifest.ex:169-178; lib/mydia/plugins/capabilities.ex:19-33; lib/mydia/plugins/host_functions.ex (require_capability, require_surface, require_data_namespace call sites) -->

### events:subscribe

A list of event names from the [event catalog](events.md#event-catalog). Each
name is also checked when the manifest is parsed, so an unknown event fails
installation instead of silently never firing. An empty list is rejected.

Required unless the plugin declares `surfaces:page` or `surfaces:shelf`, so a
page-only or shelf-only plugin may omit it. A plugin with only `surfaces:shelf`
and no `events:subscribe` is valid. Shelves use `refresh_on` events without
holding this capability.

<!-- source: lib/mydia/plugins/manifest.ex:454-458,467-487 -->

### net:http

A list of hostnames the plugin may contact, matched exactly against the host of
each request URL.

- No wildcards. A hostname containing `*` is rejected, because a wildcard
  subdomain is an exfiltration channel.
- A bare hostname only: no scheme, port, path or userinfo, and no surrounding
  whitespace. An empty or blank entry is rejected.
- The host re-checks the URL on every call and runs an SSRF gate that refuses
  private addresses unless the operator marked the host as allowed. See
  [limits](limits.md#network) for response size and timeout.

Functions: `http-request`. `link-request` and `connection-request` need this
capability too, as well as `users:connections`.

<!-- source: lib/mydia/plugins/manifest.ex:489-526; lib/mydia/plugins/host_functions.ex:658-662,1436-1440,1479-1486 -->

### data:read

A list of namespaces. The host answers with a hand-picked projection, never raw
rows or secrets.

| Namespace | Available in | Notes |
|-----------|--------------|-------|
| `media_item` | Every handler | Served by `data-read` (one item) and `data-list` (enumerate). |
| `playback_progress` | Every handler | `data-list` only. Rows for users with an active connection to the plugin. |
| `library_item` | Every handler | `data-list` only. Catalogued items with an `owned` flag. |
| `media_request` | Pages | The acting user's own rows. |
| `download` | Pages | Active downloads for items the acting user requested. |
| `collection` | Pages | The acting user's own collections. |
| `watch_history` | Pages | The acting user's progress rows, newest first. |

During a page call and a shelf fill every namespace is read as the acting user,
so a page never sees more than the person using it.

Functions: `data-read`, `data-list`.

<!-- source: lib/mydia/plugins/manifest.ex:187-197,534-548; native/mydia_plugin_sdk/wit/plugin.wit:119-131; lib/mydia/plugins/page_reads.ex:60-90 -->

### data:search

A flag. Lets a page call `search` against the acting user's library (`kind`
`library`) or the metadata catalog (`kind` `catalog`).

Functions: `search`.

<!-- source: lib/mydia/plugins/page_reads.ex:41-55 -->

### surfaces:write

A list of write surfaces. The class is not enough: the host checks the surface
on each call, and a page write is also checked against the user's role.

| Surface | Host functions | Available to |
|---------|----------------|--------------|
| `playback:watched` | `ensure-watched`, `set-watch-state` (connected users), `mark-watched-state` (page) | Events, schedules and pages |
| `collections:favorite` | `ensure-favorite` (connected users), `add-favorite` (page) | Events, schedules and pages |
| `media:add` | `media-add` | Pages only |
| `collections:write` | `collection-create`, `collection-update`, `collection-add-items`, `collection-remove-items` | Pages only |

Page writes act as the signed-in user, are journaled, and may need the user's
confirmation first. Every write function is refused during a shelf fill,
whatever the grant.

<!-- source: lib/mydia/plugins/manifest.ex:180-183,424-441; lib/mydia/plugins/host_functions.ex:1101-1120,1184-1190; lib/mydia/plugins/page_writes.ex:33-38 -->

### surfaces:page

A flag. The plugin serves a page at `/plugins/<slug>/app/` through the
`page.on-http` export and appears in the navigation. Requires a `page`
descriptor in the manifest. The page's reads and writes are gated by the other
classes above. See [Serve a page](../how-to/pages.md).

### surfaces:shelf

A flag. The plugin fills shelves on Home through the `fill-shelf` export.
Requires a `shelves` list in the manifest, and `shelves` is rejected without
this capability. A shelf-only plugin may omit `events:subscribe`. See
[Fill a shelf](../how-to/shelves.md).

<!-- source: lib/mydia/plugins/manifest.ex:454-458,768-796 -->

### state:kv

A flag. A per-instance key/value store for cursors, watermarks and dedupe sets.
Two instances of one plugin hold independent state. Sizes and quotas are in
[limits](limits.md#storage). A write past a quota returns `denied`.

Functions: `kv-get`, `kv-set`, `kv-delete`, `kv-list`, `kv-set-many`.

<!-- source: lib/mydia/plugins/kv.ex:1-30; lib/mydia/plugins/host_functions.ex:820-870 -->

### users:connections

A flag. Per-user third-party account links: the host holds the token and the
plugin sees identity and status only, never a token.

This is a cross-user capability. A user is visible to the plugin only after they
connect. `data-list` on `playback_progress` returns rows for connected users
only, and `ensure-watched` and `ensure-favorite` are rejected for a user without
an active connection.

`link-request` and `connection-request` send a request with the link's token
attached by the host. They need `net:http` as well. `set-link-token` and
`set-link-status` refuse a link the host has disabled.

Functions: `connections-list`, `links-list`, `link-request`,
`connection-request`, `propose-accounts`, `set-link-token`, `set-link-status`.

<!-- source: lib/mydia/plugins/host_functions.ex:1361-1380,1382-1440,1479-1490,1493-1500,1532-1540,1566-1570 -->

### schedule:interval

A flag. The host calls the `on-schedule` export on the interval the manifest's
`schedule` descriptor declares. A `schedule` without this capability is
rejected. See [Manifest](manifest.md) for the descriptor and the interval floor.

<!-- source: lib/mydia/plugins/manifest.ex:697-712 -->
