# Host API Reference

The contract Mydia plugins run against: the event envelope and catalog, the
capability classes and their host functions, the scheduled-handler export, and
the manifest fields that govern versioning. The current contract is
`mydia:plugin@1.6.0`.

New to plugins? Start with the
[tutorial](../tutorial/write-your-first-plugin.md). For task-oriented recipes,
see the [how-to guides](../how-to/notifications.md). For why the platform is
shaped this way (the sandbox, the capability model, the host-version floor),
see [The plugin model](../explanation/plugin-model.md).

## The event

The host delivers a typed `Event` record:

| Field | Type | Notes |
|-------|------|-------|
| `event` | `String` | The event type, e.g. `media_item.added`. |
| `category`, `severity` | `Option<String>` | Envelope classification. |
| `actor_type`, `actor_id` | `Option<String>` | Who triggered it. |
| `resource_type`, `resource_id` | `Option<String>` | What it concerns. |
| `metadata_json` | `String` | A JSON object string of per-event metadata (and any operator config). `"{}"` when empty. |

The arbitrary per-event detail (and the operator's plugin settings) ride in
`metadata_json` as a JSON object, so the typed envelope stays stable while the
payload varies by event. Parse it with any JSON crate when you need it.

### Event catalog

A plugin subscribes to events in its manifest; each must be in the catalog:

- `media_item.added`, `media_item.updated`, `media_item.removed`
- `media_file.imported`
- `download.completed`, `download.failed`
- `playback.started`, `playback.progressed`, `playback.paused`, `playback.finished`

The `playback.*` events carry an `origin` (`player`, `sync:<provider>`, or
`plugin:<slug>`) in `metadata_json`. The dispatcher never delivers an event back
to the plugin that originated it, so write-backs don't echo. `playback.progressed`
is sampled (one per 5% bucket); `playback.paused` is reserved but not yet emitted.

## Capabilities

Capabilities are **deny-by-default** and enforced server-side on every call. A
plugin can never widen its own grant. A manifest *declares* what it wants; for a
plugin installed from an index or remote package the operator approves it, while
plugins bundled in Mydia's `priv/plugins/` directory are granted their declared
set on discovery as part of the host release (see the
[manifest reference](manifest.md#capabilities)).

| Class | Meaning |
|-------|---------|
| `events:subscribe` | The event types the plugin reacts to (from the catalog above). Required unless the plugin declares `surfaces:page`. |
| `net:http` | The exact hostnames the plugin may contact. **No wildcards** (a wildcard subdomain is an exfiltration channel). |
| `data:read` | Scoped read namespaces (`media_item`, `playback_progress`, `library_item`, and the page-only `media_request`, `download`, `collection`, `watch_history`). The host returns a curated, read-only projection: never raw rows or secrets. |
| `data:search` | The `search` host function (pages only). |
| `surfaces:page` | Serve a page through the `page.on-http` export. |
| `surfaces:write` | Curated write surfaces. Vocabulary: `playback:watched` (`ensure-watched`, `mark-watched-state`), `collections:favorite` (`ensure-favorite`, `add-favorite`), `media:add` (`media-add`), `collections:write` (the `collection-*` functions). The last two are page-only. |
| `state:kv` | A per-plugin key/value store (`@max_keys` 256 keys, 64 KB per value) for watermarks, cursors, and dedupe sets. |
| `users:connections` | Per-user third-party connections: the host holds the token; the plugin gets identity + status only. **Cross-user, consent-scoped.** |
| `schedule:interval` | Run `on-schedule` on a fixed interval (manifest `schedule`, 5-minute floor). |

### Host functions

Reach capabilities through the typed SDK bindings under
`mydia_plugin_sdk::host`:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{DataRequest, OutboundRequest, ReadResult};

// data:read (a curated media-item projection).
if let Ok(ReadResult::MediaItem(item)) =
    host::data_read(&DataRequest { namespace: "media_item".into(), id })
{
    let _ = item.title;
}

// net:http (a gated outbound request). The host re-validates the URL host
// against your net:http allowlist and runs an SSRF gate on every call.
let resp = host::http_request(&OutboundRequest {
    url: "https://example.com/hook".into(),
    method: "POST".into(),
    headers: vec![("content-type".into(), "application/json".into())],
    body: Some("{}".into()),
});

// log (ungated diagnostics into the plugin's activity log).
host::log("info", "did the thing");
```

Each `result<_, host-error>` surfaces a denial (`Denied`), a bad request, a
not-found, or a network error: handle it; the host never lets a guest bypass
the gate.

### 1.1 host functions

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{ListRequest, ListItem, WatchTarget};

// state:kv (opaque per-plugin storage across invocations).
host::kv_set("watermark", "2024-06-01T00:00:00Z").ok();
let mark = host::kv_get("watermark").ok().flatten();   // Option<String>
host::kv_delete("watermark").ok();

// data:read via data-list (cursor-paginated, updated-since filtered). Walk
// next_cursor until None. playback_progress is consent-scoped to connected users.
// library_item lists catalogued items with an owned flag (a media file on disk).
let page = host::data_list(&ListRequest {
    namespace: "playback_progress".into(),
    cursor: None,
    updated_since: mark.clone(),
    limit: Some(200),
}).unwrap();
for item in page.items {
    if let ListItem::PlaybackProgress(p) = item { let _ = p.watched; }
    if let ListItem::LibraryItem(li) = item { let _ = li.owned; }
}

// surfaces:write (mark watched for a user, idempotently). Host-side external-id
// matching; the response says changed / already-watched / not-found.
host::ensure_watched(&WatchTarget {
    user_id: "…".into(),
    imdb_id: Some("tt100".into()),
    tmdb_id: None, tvdb_id: None,
    season_number: None, episode_number: None,
    watched_at: None,
}).ok();

// users:connections: identity + status only (never a token).
for c in host::connections_list().unwrap() { let _ = (c.id, c.user_id, c.status); }

// connection-request (an authenticated request). The host verifies the
// connection belongs to you, strips any guest Authorization, and injects the
// bearer token itself. You never see the token.
// host::connection_request(&c.id, &outbound_request)
```

### 1.2 host functions

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::FavoriteTarget;

// surfaces:write (add to Favorites for a user, idempotently). Requires
// surfaces:write scoped to collections:favorite and an active connection to
// the target user. Host-side external-id matching; the response says
// changed / already-favorited / not-found. Additive only: there is no
// remove counterpart, so a remote list deletion cannot strip local curation.
host::ensure_favorite(&FavoriteTarget {
    user_id: "…".into(),
    imdb_id: Some("tt100".into()),
    tmdb_id: None, tvdb_id: None,
}).ok();
```

Key guarantees:

- `ensure-watched` is **idempotent**: re-marking a watched item reports
  `already-watched` and emits no event.
- `ensure-favorite` is **idempotent**: re-adding an existing favorite reports
  `already-favorited` and writes nothing. It requires an active connection to
  the target user (consent-scoped, like `ensure-watched`). It is deliberately
  **additive only**: no host function removes favorites.
- `data-list` cursors are opaque and request-local: walk them within one run,
  never persist them.
- `kv-set` is an engine-native upsert (last write wins); keys are opaque to the
  host. Keys under `conn/<connection-id>/...` are swept when that connection is
  removed.

### 1.4 host functions and the page export

WIT 1.4.0 adds plugin pages. A guest exports `page.on-http`, and the host calls
it for every request to `/plugins/<slug>/app/*` as the signed-in user. Build the
guest with `#[mydia_plugin_sdk::plugin(on_http = handle_http)]`; without it the
generated `on-http` returns an error.

```rust
use mydia_plugin_sdk::types::{Event, PageRequest, PageResponse};

#[mydia_plugin_sdk::plugin(on_http = handle_http)]
fn on_event(_evt: Event) -> Result<String, String> { Ok("{}".into()) }

fn handle_http(req: PageRequest) -> Result<PageResponse, String> {
    Ok(PageResponse {
        status: 200,
        headers: vec![("content-type".into(), "text/html; charset=utf-8".into())],
        body: "<h1>Hello</h1>".into(),
    })
}
```

`page-request`:

| Field | Notes |
|-------|-------|
| `method` | `GET`, `POST` and so on. |
| `path` | Path below `/plugins/<slug>/app`, always starting with `/`. |
| `query` | Query string without the leading `?`, with the frame token removed. |
| `headers` | Only `content-type`, `accept` and `accept-language`. |
| `body` | `Some(text)` when the request has a body. Delivered byte for byte; the host never parses it. Bodies must be valid UTF-8 text (else 415) and at most 1 MiB (else 413). |
| `user-id`, `role`, `session-id` | Verified by the host, never taken from the browser. `role` is `admin`, `user`, `readonly` or `guest`. |
| `config-json` | The operator's plugin settings as a JSON object string. |

`page-response` carries `status` (200 to 599), `headers` and a text `body`. The
host keeps only `content-type` from the guest's headers and sets the security
headers itself (see [Serve a page](../how-to/pages.md#what-the-host-sets)). A
malformed response becomes a 502, a timeout a 504, and a plugin whose page slots
are all busy answers 503 with `Retry-After`.

Page host functions act as the user of the current `on-http` call and return
`denied` when called from any other handler (`on-event`, `on-schedule`). Their
`user-id` arguments, where they exist, are ignored.

| Function | Needs | Notes |
|----------|-------|-------|
| `search(search-request)` | `data:search` | `kind` is `library` or `catalog`. Returns `list<search-hit>`. |
| `media-add(media-add-target)` | `surfaces:write` `media:add` | Guests file a request; users and admins add to the library. |
| `collection-create(attrs)` | `collections:write` | `kind` is `manual` (default) or `smart`. |
| `collection-update(id, attrs)` | `collections:write` | |
| `collection-add-items(id, media-item-ids)` | `collections:write` | |
| `collection-remove-items(id, media-item-ids)` | `collections:write` | |
| `mark-watched-state(watch-state-target)` | `playback:watched` | |
| `add-favorite(favorite-target)` | `collections:favorite` | |
| `data-list` | `data:read` | Reads as the acting user during a page call. New rows: `media-request`, `download`, `collection`; `watch_history` returns `playback-progress` rows, newest first. |
| `http-request` | `net:http` | Page calls get a longer budget (90s and 4 MiB by default). |

Every write returns `write-outcome`:

- `done(json)`: the host performed the write; the string is the host's JSON result.
- `needs-confirmation(id)`: the user has not yet granted this surface. The write
  is parked. Hand the id to the host with
  `parent.postMessage({mydia: "confirm", ids: [id]}, "*")` and the host asks the
  user.

Writes are checked against the user's role and the plugin's grant, are recorded
in the user's journal, and can be undone from the plugin's Activity page.

Concurrency: page calls lock per user and run alongside the plugin's event and
schedule calls. At most `pool_size - 1` (minimum one) page calls per plugin run
at once, with a bounded wait before the 503. Because a page call and an event
call can overlap, keep page state in per-user `state:kv` keys (for example
`user/<user-id>/history`); a shared key written from both paths can lose an update.

### 1.5 host functions

WIT 1.5.0 is additive over 1.4.0: every 1.4 type, function and export, including
the separate `page` interface, is unchanged.

| Function | Capability | Behaviour |
|---|---|---|
| `links-list()` | `users:connections` | This instance's account links, with `id`, `role` (`owner`, `endpoint` or `user`), `user-id`, `external-user-id`, `external-username` and `status`. Never returns a token. |
| `link-request(link-id, req)` | `users:connections` + `net:http` | Sends `req` with the link's token attached using the manifest's `connection.auth_header` template (default `Authorization: Bearer {token}`). A guest-supplied header of the same name is removed first. A disabled link is refused. |
| `propose-accounts(accounts)` | `users:connections` | Records the remote accounts the plugin discovered, for the setup mapping screen and profile pages. Creates no links. |
| `set-link-token(link-id, token)` | `users:connections` | Stores a token the remote service minted for a link, such as a Plex Home profile token. The guest necessarily saw this token in the response that minted it. Refuses a disabled link and a token containing control characters. |
| `set-link-status(link-id, status, message)` | `users:connections` | Marks a link `active`, `error` or `disabled`, with an optional message. Refuses a link the host has already disabled, so a guest cannot revive it. |
| `kv-list(prefix, cursor)` | `state:kv` | Up to 200 entries whose key starts with `prefix`, in key order, with an opaque cursor for the next page. |
| `kv-set-many(entries)` | `state:kv` | Writes up to 500 entries in one transaction, or none. |
| `report-sync-run(run)` | none | Records a sync run (`started-at`, `finished-at`, `status` of `ok`, `partial` or `error`, and pulled, pushed, skipped and error counts) shown on the instance card. |

Every 1.5 import acts on the calling instance only: links, store and sync runs
are scoped to the instance the host is running the guest for.

Store quotas are per instance: `plugins.store_max_keys` (default 1,000,000) and
`plugins.store_max_bytes` (default 268,435,456, or 256 MiB). Values stay capped at
64 KiB and keys at 512 bytes. A write past a quota returns `denied`.

`playback-progress` gains `origin`, the origin tag of the row's last write.
Plugin writes are tagged `plugin:<slug>:<instance-id>`, so a plugin can skip
its own writes when pushing.

The host puts the instance's id in the guest's config as `instance_id`, in
event metadata, in the schedule tick and in setup requests.

### 1.5 exports

- `setup(req) -> setup-screen`: called with `step = "start"` when an operator
  adds or reconnects an instance, then with each screen's `step` and the
  operator's answer as `input-json`. While an `external-auth` screen is open,
  the host calls it with `step = "poll"` every `poll-after-seconds`. Choosing a
  `choice` option approves that option's `endpoints` for the instance and
  stores its `credentials` as the `owner` or `endpoint` link. Saving a
  `mapping` screen creates the `user` links and calls `setup` again with
  `{"links": [...]}`. Setup calls time out after `plugins.setup_timeout_ms`
  (default 30,000). A manifest must set `"setup": true` for the host to call it.
- `check-health() -> health`: returns `status` (`ok`, `degraded`,
  `unauthorized` or `unreachable`), an optional message, and an optional
  `action` (`reconnect` or `confirm-endpoints`) that the host shows as a button.
  The host calls it every 5 minutes for each enabled instance and from the Test
  button, under the normal event timeout.

An endpoint approved for an instance, whether typed into a `grants_host` URL
setting, picked in a `choice` screen or declared in config, may resolve to a
private address, but never to a link-local one. Nothing a guest sends can add an
approved endpoint. This sits beside the 1.4 `allow_private` url setting: a
request may reach a private address when its host is one the operator marked
`allow_private`, or when it matches an approved endpoint of the calling
instance. `http-request` and `link-request` apply both rules.

`min_host_version` is compared with the Mydia release version, not the
contract version, so a 1.5 guest sets it to the first Mydia release that
ships contract 1.5, or omits it for a bundled guest.

### fill-shelf (1.6)

WIT 1.6.0 is additive over 1.5.0: every 1.5 type, function and export is
unchanged, and there are no new host functions. A guest that declares
`surfaces:shelf` and shelves in its manifest exports `fill-shelf`, and the host
calls it for one user when a shelf is stale. Build the guest with
`#[mydia_plugin_sdk::plugin(fill_shelf = fill)]`. See
[Fill a shelf](../how-to/shelves.md).

```wit
record media-ref {
  media-type: string,          // "movie" | "tv_show"
  tmdb-id: option<s64>,
  tvdb-id: option<s64>,
  imdb-id: option<string>,
}

record shelf-request {
  shelf: string,               // the key the manifest declared
  user-id: option<string>,
  subject: option<media-ref>,
  exclude: list<media-ref>,
  limit: u32,
  now: s64,                    // Unix epoch seconds
  config-json: string,
}

record shelf-item {
  item: media-ref,
  reason: option<string>,
}

fill-shelf: func(req: shelf-request) -> result<list<shelf-item>, string>;
```

Payload rules:

- Return the list best first. An empty list means nothing to suggest and keeps
  the shelf's current items. An `Err` string is recorded as the shelf's last
  error and starts a backoff of one hour, then six hours, then the TTL.
- The host resolves `tmdb-id` first, then `tvdb-id` for a TV show. A ref with
  only `imdb-id` is dropped.
- `exclude` lists titles the host will reject. `limit` is 24; the rail shows 12.
- `reason` is plain text. The host collapses it to one line and clips it to 140
  characters.
- The host drops unresolvable, owned, requested, dismissed and restricted
  titles and duplicates, and keeps the previous list when fewer than three
  survive. It resolves at most 48 candidates per fill, four times the 12 the
  rail shows.

A fill acts as the shelf's user. `search`, `data-list`, `data-read`,
`http-request`, `connection-request`, `link-request` and the KV functions work
under their usual capabilities, and `http-request` gets the page budget. The
two request functions are outbound calls gated by grants, not writes to Mydia.
A fill runs against the plugin's default instance; a `multi_instance` plugin has
none, so its instance-scoped functions (the KV functions and `link-request`)
return `not_found` during a fill.
`data-list` is scoped to the user. `data-read` returns a media item by id
without applying the user's restrictions. A failing shelf is listed on the
plugin's row in Admin > System > Plugins, with the last error the plugin
returned.

Every write function is refused during a fill and returns `denied`, whatever
the plugin has been granted. That covers the `write-outcome` functions
(`media-add`, `collection-create`, `collection-update`,
`collection-add-items`, `collection-remove-items`, `mark-watched-state` and
`add-favorite`) and the sync writes (`ensure-watched`, `set-watch-state` and
`ensure-favorite`). The plugin's own KV store stays writable. A fill runs under
the page timeout (120 seconds by default).

### Scheduled handler

Add `on-schedule` for periodic work (declare a `schedule` and the
`schedule:interval` capability in the manifest):

```rust
use mydia_plugin_sdk::types::{Event, ScheduleTick};

#[mydia_plugin_sdk::plugin(on_schedule = on_schedule)]
fn on_event(evt: Event) -> Result<String, String> { Ok("{}".into()) }

fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    // tick.config_json carries the operator settings. Return a small JSON result;
    // include "connections_invalid": ["<user-id>"] to flag users whose token
    // the provider rejected (a 401). The host marks those connections errored.
    Ok("{\"connections_invalid\":[]}".into())
}
```

A run that takes longer than one interval is fine: the next tick is skipped
while it runs (non-reentrant), and your state must survive a wall-clock kill, so
checkpoint progress to KV as you go.

## Manifest

A plugin ships a JSON manifest declaring its identity, the events it
subscribes to, the capabilities it wants, and any operator-editable settings.
See [Manifest & Settings](manifest.md) for the full field reference and a
complete worked example.

### Host-version floor

`min_host_version` (optional, a semantic version) declares the lowest Mydia host
your plugin supports. Mydia refuses to activate a plugin whose floor exceeds the
running host with a clear `requires mydia >= X` message (the friendly wrapper
over wasmtime's hard link-time refusal). Omit it if you have no floor.

### Evolving the contract

The WIT package version **is** the ABI version. The contract evolves
**additively**: new host functions, new records, new variant cases, and new
exports are added without touching existing types or signatures. A plugin built
against an older minor keeps working: the host detects each guest's contract
version from its bytes and serves the matching interface namespace and exports,
so a `1.0` guest's `on-event` still resolves against a `1.1` host. Only a removal
or a signature change bumps the major version. Target the lowest host you need
via `min_host_version`; a `1.5` guest sets `"min_host_version": "0.16.0"` (the first host that serves it) so an
older host refuses it cleanly rather than failing to link.

## Reference

- WIT contract: `native/mydia_plugin_sdk/wit/plugin.wit`
- SDK crate: `native/mydia_plugin_sdk`
- Starter: `native/mydia_plugin_sdk/examples/minimal`
- Reference plugin: `plugins/webhook_notifier`
- Sideload helper: `native/mydia_plugin_sdk/sideload.sh`
