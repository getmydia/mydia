# Host functions

The functions a plugin imports from the host, as defined in the `host`
interface of the WIT contract (`native/mydia_plugin_sdk/wit/plugin.wit`, package
`mydia:plugin@1.6.0`). The functions a plugin exports for the host to call are
in [Guest exports](guest-exports.md).

In the Rust SDK each function is `mydia_plugin_sdk::host::<name>` with dashes
turned into underscores (`set-watch-state` is `host::set_watch_state`), and the
records are in `mydia_plugin_sdk::types`.

## Conventions

- **Capability.** Every call is checked by the host, every time. A function
  without its capability returns `denied`. See [Capabilities](capabilities.md).
- **Contract.** The contract version that introduced the function. The contract
  evolves additively, so a function never changes once published. A guest built
  against an older contract keeps working against a newer host.
- **Errors.** Every function except `log` returns `result<T, host-error>`.
  `host-error` is one of the variants below, each carrying a detail string.
- **Instance scope.** Functions that touch the store, account links or sync
  runs act on the instance the host is running the guest for.
- **Numbers.** Sizes, page lengths and quotas are in [Limits](limits.md).

| `host-error` | Meaning |
|--------------|---------|
| `denied` | The capability, namespace, surface or user connection is missing, a quota is exceeded, or a page function was called outside a page call. |
| `invalid-request` | A malformed argument, such as an empty key or an unparsable timestamp. |
| `not-found` | The id, link or instance does not exist for this plugin. |
| `network` | The request failed: refused by the egress gate, timed out, too large or unreachable. |
| `internal` | A host failure. |

## Summary

| Function | Capability | Contract |
|----------|-----------|----------|
| [`log`](#log) | none | 1.0 |
| [`http-request`](#http-request) | `net:http` | 1.0 |
| [`data-read`](#data-read) | `data:read` | 1.0 |
| [`data-list`](#data-list) | `data:read` | 1.1 |
| [`kv-get`](#kv-get) | `state:kv` | 1.1 |
| [`kv-set`](#kv-set) | `state:kv` | 1.1 |
| [`kv-delete`](#kv-delete) | `state:kv` | 1.1 |
| [`kv-list`](#kv-list) | `state:kv` | 1.5 |
| [`kv-set-many`](#kv-set-many) | `state:kv` | 1.5 |
| [`ensure-watched`](#ensure-watched) | `surfaces:write` `playback:watched` | 1.1 |
| [`set-watch-state`](#set-watch-state) | `surfaces:write` `playback:watched` | 1.2 |
| [`ensure-favorite`](#ensure-favorite) | `surfaces:write` `collections:favorite` | 1.3 |
| [`connections-list`](#connections-list) | `users:connections` | 1.1 |
| [`connection-request`](#connection-request) | `users:connections`, `net:http` | 1.1 |
| [`links-list`](#links-list) | `users:connections` | 1.5 |
| [`link-request`](#link-request) | `users:connections`, `net:http` | 1.5 |
| [`propose-accounts`](#propose-accounts) | `users:connections` | 1.5 |
| [`set-link-token`](#set-link-token) | `users:connections` | 1.5 |
| [`set-link-status`](#set-link-status) | `users:connections` | 1.5 |
| [`report-sync-run`](#report-sync-run) | none | 1.5 |
| [`search`](#search) | `data:search` | 1.4 |
| [`media-add`](#media-add) | `surfaces:write` `media:add` | 1.4 |
| [`collection-create`](#collection-create) | `surfaces:write` `collections:write` | 1.4 |
| [`collection-update`](#collection-update) | `surfaces:write` `collections:write` | 1.4 |
| [`collection-add-items`](#collection-add-items) | `surfaces:write` `collections:write` | 1.4 |
| [`collection-remove-items`](#collection-remove-items) | `surfaces:write` `collections:write` | 1.4 |
| [`mark-watched-state`](#mark-watched-state) | `surfaces:write` `playback:watched` | 1.4 |
| [`add-favorite`](#add-favorite) | `surfaces:write` `collections:favorite` | 1.4 |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:10-50,541-668; lib/mydia/plugins/host_functions.ex (require_capability, require_surface call sites) -->

## General

### log

Capability: none. Contract 1.0.

`log(level: string, message: string)`

Writes a line to the plugin's activity log. Ungated, returns nothing, and never
traps the guest.

| Argument | Type | Notes |
|----------|------|-------|
| `level` | `string` | `debug`, `info`, `warn` or `error`. Any other value is logged as `info`. |
| `message` | `string` | The line to record. |

### http-request

Capability: [`net:http`](capabilities.md#nethttp). Contract 1.0.

`http-request(req: outbound-request) -> result<outbound-response, host-error>`

Sends an outbound HTTP request. The host checks the URL's hostname against the
granted `net:http` list on every call and runs an SSRF gate that refuses
private addresses, unless the operator marked the host as allowed or the
request matches an endpoint approved for the calling instance (a private
address is accepted there, a link-local one never is). Response size and
timeout depend on the handler: see [Limits](limits.md#network).

`outbound-request`:

| Field | Type | Notes |
|-------|------|-------|
| `url` | `string` | The full URL. Its host must be in `net:http`. |
| `method` | `string` | The host uses `GET` when empty. |
| `headers` | `list<tuple<string, string>>` | Request headers. |
| `body` | `option<string>` | A text body. |

`outbound-response`:

| Field | Type | Notes |
|-------|------|-------|
| `status` | `u16` | The HTTP status. |
| `ok` | `bool` | True for a status from 200 to 299. |
| `body` | `option<string>` | Present when the response body is valid UTF-8. |
| `body-encoding` | `option<string>` | `"binary"` when the body was not UTF-8 and was left out. Otherwise absent. |

A non-2xx status is a normal response, not an error. Failures map as follows:

| Failure | Error |
|---------|-------|
| The host is not in the grant, whether or not the manifest declared it | `denied` |
| A malformed URL (scheme other than http or https, no host, userinfo, an ambiguous numeric host) or an unsupported method | `invalid-request` |
| A private or blocked address, a failed lookup, a timeout, an oversized response or a transport failure | `network` |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:96-111,551-553; lib/mydia/plugins/host_functions.ex:658-746; lib/mydia/plugins/net/gate.ex:145-160 -->

## Reading data

### data-read

Capability: [`data:read`](capabilities.md#dataread), scoped to the namespace. Contract 1.0.

`data-read(req: data-request) -> result<read-result, host-error>`

Reads one item by id. Only the `media_item` namespace is served, and the result
is the `media-item` case of `read-result`. Any other namespace returns
`invalid-request`. In a page call or a shelf fill the read runs as the acting
user, so an id that user cannot see answers `not-found`. In an event or
schedule handler it reads as the system.

`data-request`:

| Field | Type | Notes |
|-------|------|-------|
| `namespace` | `string` | `media_item`. |
| `id` | `string` | The media item id. |

`media-item`:

| Field | Type |
|-------|------|
| `id` | `string` |
| `item-type` | `string` |
| `title` | `string` |
| `original-title` | `option<string>` |
| `year` | `option<u32>` |
| `tmdb-id`, `tvdb-id` | `option<s64>` |
| `imdb-id` | `option<string>` |
| `overview`, `tagline` | `option<string>` |
| `runtime` | `option<u32>` |
| `genres` | `list<string>` |
| `poster-path`, `backdrop-path` | `option<string>` |
| `rating` | `option<f64>` |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:70-94,113-117; lib/mydia/plugins/host_functions.ex:760-815 -->

### data-list

Capability: [`data:read`](capabilities.md#dataread), scoped to the namespace. Contract 1.1.

`data-list(req: list-request) -> result<list-result, host-error>`

Lists rows of a namespace with a cursor. Walk `next-cursor` until it is absent.
Cursors are opaque and last for one run, so never store one. Page size is in
[Limits](limits.md#data-reads).

`list-request`:

| Field | Type | Notes |
|-------|------|-------|
| `namespace` | `string` | See the table below. |
| `cursor` | `option<string>` | The `next-cursor` of the previous page. |
| `updated-since` | `option<string>` | RFC 3339. Keeps rows changed at or after it. For `watch_history` it bounds `last-watched-at` instead. |
| `limit` | `option<u32>` | A hint, clamped by the host. |

`list-result` has `items: list<list-item>` and `next-cursor: option<string>`.
Each `list-item` is one case of a variant, matching the namespace:

| Namespace | `list-item` case | Notes |
|-----------|------------------|-------|
| `media_item` | `media-item` | Same record as [`data-read`](#data-read). |
| `playback_progress` | `playback-progress` | Outside a page, only users with an active connection to the plugin. |
| `library_item` | `library-item` | Catalogued items with an `owned` flag. |
| `media_request` | `media-request-row` | Acting user only. The user's own requests. |
| `download` | `download-row` | Acting user only. |
| `collection` | `collection-row` | Acting user only. The user's own collections. |
| `watch_history` | `playback-progress` | Acting user only. Newest first by `last-watched-at`, no cursor. An episode row's `media-item-id` is its show's id. |

During a page call or a shelf fill every namespace is read as the acting user.
Outside them the plugin sees the whole instance, with `playback_progress`
limited to connected users. The `media_request`, `download`, `collection` and
`watch_history` namespaces need an acting user, so they return `denied` from
event and schedule handlers.

`playback-progress`:

| Field | Type | Notes |
|-------|------|-------|
| `user-id` | `string` | |
| `item-type` | `string` | `movie` or `episode`. |
| `media-item-id`, `episode-id` | `option<string>` | |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `imdb-id` | `option<string>` | |
| `season-number`, `episode-number` | `option<u32>` | |
| `watched` | `bool` | |
| `position-seconds` | `option<u32>` | Resume position. Absent when never started. Since 1.2. |
| `duration-seconds` | `option<u32>` | Runtime. Absent when unknown. Since 1.2. |
| `last-watched-at` | `option<string>` | RFC 3339. Absent when never watched. |
| `updated-at` | `string` | RFC 3339. The row's update time. |
| `origin` | `option<string>` | The origin tag of the last write, such as `player` or `plugin:<slug>:<instance-id>`. A plugin can skip its own writes when pushing. Since 1.5. |

`library-item`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `string` | |
| `item-type` | `string` | `movie` or `tv_show`. |
| `title` | `string` | |
| `year` | `option<u32>` | |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `imdb-id` | `option<string>` | |
| `owned` | `bool` | True when at least one untrashed media file exists. Episode files count for shows. |
| `updated-at` | `string` | RFC 3339. |

`media-request-row`:

| Field | Type | Notes |
|-------|------|-------|
| `id`, `title`, `media-type` | `string` | |
| `status` | `string` | `pending`, `approved` or `rejected`. |
| `year` | `option<u32>` | |
| `tmdb-id` | `option<s64>` | |
| `updated-at` | `string` | |

`download-row`:

| Field | Type | Notes |
|-------|------|-------|
| `id`, `title`, `status` | `string` | |
| `progress` | `option<f64>` | 0.0 to 100.0. |
| `eta-seconds` | `option<s64>` | |

`collection-row`:

| Field | Type | Notes |
|-------|------|-------|
| `id`, `name` | `string` | |
| `kind` | `string` | `manual` or `smart`. |
| `item-count` | `u32` | |
| `is-system` | `bool` | |
| `updated-at` | `string` | |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:121-179,261-279,380-411; lib/mydia/plugins/host_functions.ex:880-960; lib/mydia/plugins/page_reads.ex -->

### search

Capability: [`data:search`](capabilities.md#datasearch). Contract 1.4. Page calls and shelf fills only.

`search(req: search-request) -> result<list<search-hit>, host-error>`

Searches the acting user's library or the metadata catalog. Called from an
event or schedule handler it returns `denied`.

`search-request`:

| Field | Type | Notes |
|-------|------|-------|
| `kind` | `search-kind` | `library` or `catalog`. |
| `query` | `string` | |
| `media-type` | `option<string>` | `movie` or `tv_show`. Both when absent. |
| `limit` | `option<u32>` | Clamped and defaulted: see [Limits](limits.md#data-reads). |

`search-hit`:

| Field | Type | Notes |
|-------|------|-------|
| `kind` | `search-kind` | |
| `item-type` | `string` | `movie`, `tv_show`, `episode` or `collection`. |
| `title` | `string` | |
| `year` | `option<u32>` | |
| `media-item-id` | `option<string>` | Set for library hits. |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `poster-path`, `overview` | `option<string>` | |

Catalog results stop after a bounded number of provider pages: see
[Limits](limits.md#data-reads).

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:338-360,621-623; lib/mydia/plugins/page_reads.ex:37-55,287-292 -->

## Store

The `state:kv` store is per plugin instance. Keys are opaque UTF-8 strings,
values are UTF-8 strings. Key and value sizes, quotas and the keys the host
sweeps are in [Limits](limits.md#storage). A write past a quota returns
`denied`. Keep per-user data under per-user keys (for example
`user/<user-id>/history`), because a page call and an event call can run at the
same time and a shared key written from both can lose an update.

### kv-get

Capability: [`state:kv`](capabilities.md#statekv). Contract 1.1.

`kv-get(key: string) -> result<option<string>, host-error>`

Returns the value, or `none` for a missing key.

### kv-set

Capability: [`state:kv`](capabilities.md#statekv). Contract 1.1.

`kv-set(key: string, value: string) -> result<bool, host-error>`

Upserts a value. The last write wins. Returns `true` on success.

### kv-delete

Capability: [`state:kv`](capabilities.md#statekv). Contract 1.1.

`kv-delete(key: string) -> result<bool, host-error>`

Deletes a key. Returns `true` whether or not the key existed.

### kv-list

Capability: [`state:kv`](capabilities.md#statekv). Contract 1.5.

`kv-list(prefix: string, cursor: option<string>) -> result<kv-page, host-error>`

Lists entries whose key starts with `prefix`, in key order. `kv-page` has
`entries: list<kv-entry>` (each `key` and `value`) and
`next-cursor: option<string>`. Pass `next-cursor` back as `cursor` for the next
page. The page length is in [Limits](limits.md#storage).

### kv-set-many

Capability: [`state:kv`](capabilities.md#statekv). Contract 1.5.

`kv-set-many(entries: list<kv-entry>) -> result<_, host-error>`

Writes every entry in one transaction, or none of them. A batch over the
maximum returns `invalid-request` ([Limits](limits.md#storage)).

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:429-430,567-578,660-664; lib/mydia/plugins/host_functions.ex:817-880; lib/mydia/plugins/kv.ex -->

## Watch state and favorites

These write for a user on the plugin's behalf, so the user must have an active
connection to the plugin, or the call returns `denied`. They match the item
host-side from external ids, trying `tmdb-id`, `tvdb-id` and `imdb-id`
candidates in order, and report `not-found` when nothing matches. Episode
coordinates (`season-number`, `episode-number`) pin an episode within the
matched show. The writes are tagged with the origin
`plugin:<slug>:<instance-id>`, so the [event](events.md) they cause is not
delivered back to the same plugin. They are refused during a shelf fill. A page
uses [`mark-watched-state`](#mark-watched-state) and [`add-favorite`](#add-favorite)
instead.

### ensure-watched

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `playback:watched`, and an active connection to the target user. Contract 1.1.

`ensure-watched(target: watch-target) -> result<ensure-watched-result, host-error>`

Marks an item watched, idempotently. Kept for 1.1 guests: a newer guest should
use [`set-watch-state`](#set-watch-state), which can also clear a watch.

`watch-target`:

| Field | Type | Notes |
|-------|------|-------|
| `user-id` | `string` | Required. |
| `imdb-id` | `option<string>` | |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `season-number`, `episode-number` | `option<u32>` | |
| `watched-at` | `option<string>` | RFC 3339. Now when absent. |

`ensure-watched-result` has `status`: `changed`, `already-watched` or
`not-found`. Re-marking a watched item reports `already-watched` and emits no
event.

### set-watch-state

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `playback:watched`, and an active connection to the target user. Contract 1.2.

`set-watch-state(target: watch-state-target) -> result<ensure-watched-result, host-error>`

Sets the watch state of an item, including clearing it, optionally with a
resume position. It returns the same `ensure-watched-result` as
`ensure-watched`.

`watch-state-target`:

| Field | Type | Notes |
|-------|------|-------|
| `user-id` | `string` | Required. |
| `imdb-id` | `option<string>` | |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `season-number`, `episode-number` | `option<u32>` | |
| `watched` | `bool` | `false` clears the watch. |
| `position-seconds` | `option<u32>` | Resume position. |
| `duration-seconds` | `option<u32>` | Runtime. |
| `watched-at` | `option<string>` | RFC 3339. |

### ensure-favorite

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:favorite`, and an active connection to the target user. Contract 1.3.

`ensure-favorite(target: favorite-target) -> result<ensure-favorite-result, host-error>`

Adds an item to the user's Favorites, idempotently. It is additive only: no
function removes a favorite, so a deletion on the remote service cannot strip
local curation. Favorites are always item-level, so there are no episode
coordinates. A title the user may not see is reported as `not-found`.

`favorite-target`:

| Field | Type | Notes |
|-------|------|-------|
| `user-id` | `string` | Required. |
| `imdb-id` | `option<string>` | |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |

`ensure-favorite-result` has `status`: `changed`, `already-favorited` or
`not-found`. Re-adding an existing favorite writes nothing.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:181-220,281-301,585-593,609-614; lib/mydia/plugins/host_functions.ex:1100-1200,1358-1366 -->

## Accounts and links

An instance has account links: an `owner` link and `endpoint` links hold
credentials for the remote service, and `user` links connect one Mydia user to
one remote account. The host holds every token. A guest receives identity and
status only, never a token; the exception is a token the guest itself minted
and hands to [`set-link-token`](#set-link-token).

### connections-list

Capability: [`users:connections`](capabilities.md#usersconnections). Contract 1.1.

`connections-list() -> result<list<connection>, host-error>`

Lists the instance's user links in the 1.1 shape. A disabled link is not
listed. New guests should use [`links-list`](#links-list).

`connection`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `string` | The link id. |
| `user-id` | `string` | |
| `external-user-id`, `external-username` | `option<string>` | |
| `status` | `connection-status` | `connected` or `error`. |

### connection-request

Capability: [`users:connections`](capabilities.md#usersconnections) and [`net:http`](capabilities.md#nethttp). Contract 1.1.

`connection-request(connection-id: string, req: outbound-request) -> result<outbound-response, host-error>`

The 1.1 form of [`link-request`](#link-request), limited to `user` links. The
host checks that the connection belongs to the calling instance, removes any
guest `Authorization` header and adds the token itself. A disabled link and a
link with no token yet are refused. The request host is checked like any
`http-request`: against the granted `net:http` hostnames or an approved
endpoint of the instance.

### links-list

Capability: [`users:connections`](capabilities.md#usersconnections). Contract 1.5.

`links-list() -> result<list<account-link>, host-error>`

Lists the instance's account links, never with a token.

`account-link`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `string` | |
| `role` | `link-role` | `owner`, `endpoint` or `user`. |
| `user-id` | `option<string>` | The Mydia user, for a `user` link. |
| `external-user-id`, `external-username` | `option<string>` | |
| `status` | `link-status` | `active`, `error` or `disabled`. |

### link-request

Capability: [`users:connections`](capabilities.md#usersconnections) and [`net:http`](capabilities.md#nethttp). Contract 1.5.

`link-request(link-id: string, req: outbound-request) -> result<outbound-response, host-error>`

Sends `req` with the link's token attached. The header comes from the
manifest's `connection.auth_header` template, which defaults to
`Authorization: Bearer {token}`. A guest-supplied header of the same name is
removed first, whatever its case. A disabled link, a link with no token yet and
a link of another instance are refused. The request host is checked like
`http-request`, against the granted `net:http` hostnames or an approved
endpoint of the instance.

### propose-accounts

Capability: [`users:connections`](capabilities.md#usersconnections). Contract 1.5.

`propose-accounts(accounts: list<remote-account>) -> result<_, host-error>`

Records the remote accounts the plugin discovered, for the setup mapping screen
and profile pages. It creates no links. The maximum count is in
[Limits](limits.md#data-reads).

`remote-account`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `string` | Required and not empty. |
| `name` | `string` | Required. Clipped ([Limits](limits.md#data-reads)). |
| `admin` | `bool` | |

### set-link-token

Capability: [`users:connections`](capabilities.md#usersconnections). Contract 1.5.

`set-link-token(link-id: string, token: string) -> result<_, host-error>`

Stores a token the remote service minted for a link, such as a Plex Home
profile token. The guest necessarily saw this token in the response that
minted it. The token must be non-empty, within the size in
[Limits](limits.md#data-reads), and free of control characters. A disabled link
is refused.

### set-link-status

Capability: [`users:connections`](capabilities.md#usersconnections). Contract 1.5.

`set-link-status(link-id: string, status: link-status, message: option<string>) -> result<_, host-error>`

Marks a link `active` or `error`, with an optional message. A guest cannot set
`disabled`, which is the host's switch: that value returns `denied`. A link the
host has already disabled is refused too, so a guest cannot revive it.

### report-sync-run

Capability: none. Contract 1.5.

`report-sync-run(run: sync-run-report) -> result<_, host-error>`

Records one sync run for the calling instance, shown on the instance card.
Ungated. A timestamp that is not RFC 3339 returns `invalid-request`.

`sync-run-report`:

| Field | Type | Notes |
|-------|------|-------|
| `started-at`, `finished-at` | `string` | RFC 3339. |
| `status` | `sync-run-status` | `ok`, `partial` or `error`. |
| `pulled`, `pushed`, `skipped`, `errors` | `u32` | Counts. |
| `message` | `option<string>` | Clipped ([Limits](limits.md#data-reads)). |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:222-238,415-442,595-605,640-667; lib/mydia/plugins/host_functions.ex:1369-1610,1202-1260 -->

## Page writes

These functions act as the signed-in user of the current `on-http` call and
return `denied` from any other handler, including `fill-shelf`. Their
`user-id` arguments, where they exist, are ignored. Each needs the write
surface in its row and returns a `write-outcome`:

- `done(string)`: the host performed the write; the string is the host's JSON
  result.
- `needs-confirmation(string)`: the user has not yet granted this surface, so
  the write is parked under the returned id. The page hands the id to the host
  with `parent.postMessage({mydia: "confirm", ids: [id]}, "*")` and the host asks
  the user.

Writes are checked against the user's role and the plugin's grant, are recorded
in the user's journal and can be undone from the plugin's Activity page. See
[Serve a page](../how-to/pages.md).

### media-add

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `media:add`. Contract 1.4.

`media-add(target: media-add-target) -> result<write-outcome, host-error>`

Adds a title. The host routes by role: a guest files a request, a user or an
admin adds to the library.

`media-add-target`:

| Field | Type | Notes |
|-------|------|-------|
| `media-type` | `string` | `movie` or `tv_show`. |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |

### collection-create

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:write`. Contract 1.4.

`collection-create(attrs: collection-attrs) -> result<write-outcome, host-error>`

Creates a collection for the acting user.

`collection-attrs` (used by `collection-create` and `collection-update`):

| Field | Type | Notes |
|-------|------|-------|
| `name` | `option<string>` | |
| `description` | `option<string>` | |
| `kind` | `option<string>` | `manual` (the default) or `smart`. Create only. |
| `smart-rules-json` | `option<string>` | The rules of a smart collection, as a JSON string. |

### collection-update

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:write`. Contract 1.4.

`collection-update(id: string, attrs: collection-attrs) -> result<write-outcome, host-error>`

Changes the name, description or smart rules of one of the user's collections.

### collection-add-items

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:write`. Contract 1.4.

`collection-add-items(id: string, media-item-ids: list<string>) -> result<write-outcome, host-error>`

Adds media items to a manual collection. A smart collection has no manual items
and returns `invalid-request`.

### collection-remove-items

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:write`. Contract 1.4.

`collection-remove-items(id: string, media-item-ids: list<string>) -> result<write-outcome, host-error>`

Removes media items from a manual collection. A smart collection returns
`invalid-request`.

### mark-watched-state

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `playback:watched`. Contract 1.4.

`mark-watched-state(target: watch-state-target) -> result<write-outcome, host-error>`

Sets the watch state for the acting user. The argument is the same
`watch-state-target` as [`set-watch-state`](#set-watch-state), and its
`user-id` is ignored.

### add-favorite

Capability: [`surfaces:write`](capabilities.md#surfaceswrite) with `collections:favorite`. Contract 1.4.

`add-favorite(target: favorite-target) -> result<write-outcome, host-error>`

Adds a favorite for the acting user. The argument is the same
`favorite-target` as [`ensure-favorite`](#ensure-favorite), and its `user-id`
is ignored.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:330-378,616-638; lib/mydia/plugins/page_writes.ex:20-60,520-535; lib/mydia/plugins/page_context.ex:21-42 -->

## Contract versions

The WIT package version is the ABI version. The contract evolves additively:
new host functions, records, variant cases, optional fields and exports are
added without touching existing types or signatures. A guest built against an
older minor keeps working, because the host detects each guest's contract
version from its bytes and serves the matching interface and exports. Only a
removal or a signature change bumps the major version. A guest built against a
newer contract than the host provides fails to instantiate, which is what
`min_host_version` in the [manifest](manifest.md#host-version-floor) guards
against.

| Contract | Adds |
|----------|------|
| 1.0 | `on-event`, `http-request`, `data-read`, `log`. |
| 1.1 | The store (`kv-get`, `kv-set`, `kv-delete`), `data-list`, `ensure-watched`, `connections-list`, `connection-request` and the `on-schedule` export. |
| 1.2 | `set-watch-state`, and `position-seconds` and `duration-seconds` on `playback-progress`. |
| 1.3 | `ensure-favorite`, and the `library_item` namespace with `library-item`. |
| 1.4 | Plugin pages (`on-http`), `search`, `media-add`, the `collection-*` writes, `mark-watched-state`, `add-favorite`, and the `media-request`, `download` and `collection` list cases. |
| 1.5 | Instances and account links (`links-list`, `link-request`, `propose-accounts`, `set-link-token`, `set-link-status`), `kv-list`, `kv-set-many`, `report-sync-run`, `origin` on `playback-progress`, and the `setup` and `check-health` exports. |
| 1.6 | The `fill-shelf` export and the `media-ref`, `shelf-request` and `shelf-item` records. No new host functions. |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:1-51 -->
