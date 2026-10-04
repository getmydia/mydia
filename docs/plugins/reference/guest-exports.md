# Guest exports

The functions a plugin exports for the host to call, as defined in the
`handler` and `page` interfaces of the WIT contract
(`native/mydia_plugin_sdk/wit/plugin.wit`, package `mydia:plugin@1.6.0`). The
functions a plugin may call are in [Host functions](host-functions.md).

A guest implements `on-event` and any of the others it needs. The
`#[mydia_plugin_sdk::plugin]` macro wires them up from plain functions:

| Export | Interface | Contract | Macro argument | Declared by |
|--------|-----------|----------|----------------|-------------|
| [`on-event`](#on-event) | `handler` | 1.0 | the annotated function | [`events:subscribe`](capabilities.md#eventssubscribe) |
| [`on-schedule`](#on-schedule) | `handler` | 1.1 | `on_schedule = ...` | [`schedule:interval`](capabilities.md#scheduleinterval) |
| [`on-http`](#on-http) | `page` | 1.4 | `on_http = ...` | [`surfaces:page`](capabilities.md#surfacespage) |
| [`setup`](#setup) | `handler` | 1.5 | `setup = ...` | `"setup": true` in the manifest |
| [`check-health`](#check-health) | `handler` | 1.5 | `check_health = ...` | nothing: called for every enabled instance of a 1.5 guest |
| [`fill-shelf`](#fill-shelf) | `handler` | 1.6 | `fill_shelf = ...` | [`surfaces:shelf`](capabilities.md#surfacesshelf) |

Every export returns a `result`. An `Err` string is surfaced as a plugin error
and recorded in the plugin's activity log. Each call runs in a fresh component
instance, and the timeouts are in [Limits](limits.md#runtime).

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:670-716; lib/mydia/plugins/host.ex:585-640 -->

## on-event

Contract 1.0.

`on-event(evt: event) -> result<string, string>`

Called once for each [event](events.md) the plugin subscribed to, for every
enabled instance. The `event` record and the `metadata-json` layout are in
[Events](events.md#event-envelope).

Return a small JSON object string, for example `{"delivered":true,"status":204}`.
The host reads it as the call's result. An `Err` string is surfaced as a plugin
error. The call is killed when it exceeds the event timeout.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:58-68,676-679; lib/mydia/plugins/notifier/delivery.ex:67 -->

## on-schedule

Contract 1.1.

`on-schedule(tick: schedule-tick) -> result<string, string>`

Called on the interval the manifest's `schedule` declares, for plugins that hold
`schedule:interval`. See [Manifest](manifest.md) for the descriptor and the
interval floor. A 1.0 guest does not export it, and the call then fails soft.

`schedule-tick`:

| Field | Type | Notes |
|-------|------|-------|
| `slug` | `string` | The plugin's slug. |
| `now` | `s64` | Unix epoch seconds at invocation. |
| `config-json` | `string` | The operator's settings as a JSON object string. `"{}"` when empty. |

Return a small JSON object string. One key is read by the host:
`connections_invalid`, an array of user ids whose token the remote service
rejected (a 401). The host marks those users' active links `error`, and only
those of this instance.

A run that outlasts one interval is fine. The next tick is skipped while it
runs, so ticks never overlap, and a run killed by the timeout stops without
warning, so checkpoint progress to the store as you go.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:240-247,681-685; lib/mydia/jobs/plugin_scheduler.ex:109-135; docs/plugins/reference/manifest.md -->

## on-http

Contract 1.4. Interface `page`.

`on-http(req: page-request) -> result<page-response, string>`

Called for every request to `/plugins/<slug>/app/*`, as the signed-in user, for
plugins that hold `surfaces:page`. A guest built without `on_http` returns an
error for every request.

`page-request`:

| Field | Type | Notes |
|-------|------|-------|
| `method` | `string` | `GET`, `POST` and so on. |
| `path` | `string` | The path below `/plugins/<slug>/app`, always starting with `/`. |
| `query` | `string` | The query string without the leading `?`, with the frame token removed. |
| `headers` | `list<tuple<string, string>>` | Only `content-type`, `accept` and `accept-language`. |
| `body` | `option<string>` | Present when the request has a body, delivered byte for byte and never parsed by the host. Must be valid UTF-8 text (else 415) and within the page body limit (else 413). |
| `user-id` | `string` | The signed-in user, verified by the host. |
| `role` | `string` | `admin`, `user`, `readonly` or `guest`, verified by the host. |
| `session-id` | `string` | Verified by the host. |
| `config-json` | `string` | The operator's plugin settings as a JSON object string. |

`user-id`, `role` and `session-id` are never taken from the browser.

`page-response`:

| Field | Type | Notes |
|-------|------|-------|
| `status` | `u16` | 200 to 599. |
| `headers` | `list<tuple<string, string>>` | The host keeps only `content-type`. |
| `body` | `string` | A text body. |

The host sets the security headers itself, listed under
[Page response headers](#page-response-headers). The numbers are in
[Limits](limits.md#pages).

When the guest does not answer, the host answers for it. These responses have an
empty body:

| Status | When |
|--------|------|
| 401 | The frame token is missing, invalid, expired or issued for another plugin, or its user no longer exists. |
| 404 | The plugin is disabled or not approved for `surfaces:page`, or does not exist. |
| 413 | The request body is over the limit. |
| 415 | The request body is not UTF-8 text. |
| 502 | The guest returned `Err`, or a malformed response (a status outside 200 to 599). |
| 503 | All of the plugin's page slots are busy. The response carries `Retry-After`. |
| 504 | The call timed out. |

During an `on-http` call the page host functions act as the signed-in user: see
[Page writes](host-functions.md#page-writes). `search` and `data-list` read as
that user, and `http-request` gets the larger page budget
([Limits](limits.md#network)).

Page calls lock per user and run alongside the plugin's event and schedule
calls. Because a page call and an event call can overlap, keep page state in
per-user store keys.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:305-328,702-708; lib/mydia_web/controllers/plugin_page_controller.ex -->

### Page response headers

The host serves every page response with its own headers, so a plugin cannot
loosen them:

| Header | Value |
|--------|-------|
| `content-security-policy` | `default-src 'self' 'unsafe-inline'`, `connect-src 'self'`, `img-src 'self' data: https://image.tmdb.org https://artworks.thetvdb.com`, `sandbox allow-scripts allow-forms` and `frame-ancestors 'self'`. Inline scripts and styles work. Nothing loads from another origin, and the page can only call itself. |
| `cache-control` | `private, no-store` |
| `x-content-type-options` | `nosniff` |
| `referrer-policy` | `no-referrer` |

Of the headers a guest returns, only `content-type` is kept. Mydia's own
stylesheet is served to pages at `/assets/css/app.css`.

<!-- source: lib/mydia_web/controllers/plugin_page_controller.ex:30-37,177-180 -->

## setup

Contract 1.5. The manifest must set `"setup": true` for the host to call it.

`setup(req: setup-request) -> result<setup-screen, string>`

One step of a setup wizard that the host renders. The guest decides which
screen comes next; the host owns the session, validates what it can, applies
what a screen carries and renders the screen. The call runs under the setup
timeout ([Limits](limits.md#runtime)).

The host calls it with `step = "start"` when an operator adds an instance or
reconnects one. After each screen it calls it again with that screen's `step`
and the operator's answer as `input-json`. While an `external-auth` screen is
open it calls it with `step = "poll"` every `poll-after-seconds`.

`setup-request`:

| Field | Type | Notes |
|-------|------|-------|
| `step` | `string` | `start` first, `poll` while an `external-auth` screen is open, otherwise the previous screen's `step`. |
| `input-json` | `string` | The operator's answers to the previous screen. `"{}"` for `start` and `poll`. |
| `state-json` | `string` | The previous screen's `next-state-json`. `"{}"` for `start`. |
| `config-json` | `string` | The instance settings, shaped like the injected config. |

`setup-screen`:

| Field | Type | Notes |
|-------|------|-------|
| `step` | `string` | The id the host sends back with the operator's answer. |
| `body` | `screen-body` | The screen. One of the cases below. |
| `next-state-json` | `string` | Opaque state the host hands back on the next call as `state-json`. |
| `credentials` | `list<credential>` | Tokens to store, applied as the screen is received. |
| `error` | `option<string>` | Shown above the screen. The screen is rendered again. |

`credential` has `role` (`owner` or `endpoint`, never `user`) and `token`. The
host stores it as that link of the instance. A credential with any other role
or an empty token is ignored.

### Screens

`screen-body` is a variant:

| Case | Record | Notes |
|------|--------|-------|
| `form` | `form-screen` | `title` and a list of `setup-field`. |
| `choice` | `choice-screen` | `title` and a list of `choice-option`. |
| `external-auth` | `external-auth-screen` | `url`, `poll-after-seconds` and an optional `message`. |
| `mapping` | `mapping-screen` | `title`, the `remote-account` list and `mapping-suggestion` list. |
| `done` | `string` | The setup is finished: the string is the summary, and the host enables the new instance. |

`setup-field`:

| Field | Type | Notes |
|-------|------|-------|
| `key` | `string` | The key of this field in the next `input-json`. |
| `label` | `string` | |
| `field-type` | `string` | `string`, `url`, `secret`, `enum` or `text`. |
| `required` | `bool` | The host refuses an empty answer for a required field. |
| `options` | `list<string>` | The values of an `enum` field. |
| `default-value` | `option<string>` | |

A `url` field is approved as an endpoint of the instance when the operator
submits the form.

`choice-option`:

| Field | Type | Notes |
|-------|------|-------|
| `id` | `string` | Sent back as `option_id` in the next `input-json`. |
| `label` | `string` | |
| `detail`, `badge` | `option<string>` | Secondary text and a tag. |
| `endpoints` | `list<endpoint>` | `scheme`, `host` and `port` triples approved for the instance when the option is chosen. |
| `credentials` | `list<credential>` | Stored as the `owner` or `endpoint` link when the option is chosen. |

`mapping-screen` pairs remote accounts with Mydia users. `remote-account` is the
record used by [`propose-accounts`](host-functions.md#propose-accounts). A
`mapping-suggestion` has `remote-account-id` and `user-id`. The host fills in
suggestions the guest left out, and fills an empty account list from the
accounts the guest proposed. Saving the screen creates the `user` links and
calls `setup` again with `{"links": [...]}` as `input-json`, one entry per link
with `link_id`, `remote_account_id` and `user_id`. One Mydia user can be linked
to one remote account only.

An endpoint approved by a `url` field, a `choice` option or declared in config
may resolve to a private address, but never to a link-local one. Nothing a
guest sends outside these screens adds an approved endpoint. See
[`http-request`](host-functions.md#http-request).

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:444-499,687-690; lib/mydia/plugins/setup.ex; lib/mydia/plugins/host.ex:601-625,992 -->

## check-health

Contract 1.5. The host calls it for every enabled instance of a plugin that
exports it, whatever the manifest's `setup` flag says.

`check-health() -> result<health, string>`

Reports the instance's current health for the admin card. It takes no
argument.

`health`:

| Field | Type | Notes |
|-------|------|-------|
| `status` | `health-status` | `ok`, `degraded`, `unauthorized` or `unreachable`. |
| `message` | `option<string>` | Shown with the status. |
| `action` | `option<health-action>` | `reconnect` or `confirm-endpoints`. The host shows it as a button. |

The host calls it every 5 minutes for each enabled instance, and when the
operator presses Test. It runs under the event timeout
([Limits](limits.md#runtime)). The host caches the result and never calls the
guest while rendering a page. Results the host derives itself:

| Situation | Status shown |
|-----------|--------------|
| The guest returns `Err`, times out, or the plugin is not running | `unreachable`, with the error as the message. |
| A status the host does not know | `unreachable`. |
| The guest has no `check-health` export (before contract 1.5) | `unsupported`. The guest is never called, and this is not an outage. |
| The instance is disabled | `disabled`. The guest is not called. |
| No result yet | `unknown`. |

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:444-450,692-693; lib/mydia/plugins/instance_health.ex -->

## fill-shelf

Contract 1.6. Needs `surfaces:shelf` and a `shelves` list in the manifest.

`fill-shelf(req: shelf-request) -> result<list<shelf-item>, string>`

Called for one user when one of the plugin's shelves is stale. The guest
returns the titles for the shelf, best first. The host verifies, stores and
renders them. For a walkthrough see [Fill a shelf](../how-to/shelves.md).

`shelf-request`:

| Field | Type | Notes |
|-------|------|-------|
| `shelf` | `string` | The key the manifest declared. |
| `user-id` | `option<string>` | The user the shelf belongs to. Absent for a server-wide shelf. |
| `subject` | `option<media-ref>` | The title the shelf is about. Absent on the home page. |
| `exclude` | `list<media-ref>` | Titles the host will reject, because they are already shown or were dismissed. Returning them wastes a slot. |
| `limit` | `u32` | The most items worth returning ([Limits](limits.md#shelves)). |
| `now` | `s64` | Unix epoch seconds. |
| `config-json` | `string` | The operator's settings as a JSON object string. |

`shelf-item` has `item: media-ref` and `reason: option<string>`. `media-ref`:

| Field | Type | Notes |
|-------|------|-------|
| `media-type` | `string` | `movie` or `tv_show`. |
| `tmdb-id`, `tvdb-id` | `option<s64>` | |
| `imdb-id` | `option<string>` | |

### Return contract

- Return the list best first. An empty list means nothing to suggest and keeps
  the shelf's current items.
- An `Err` string is recorded as the shelf's last error and starts a backoff.
  The host shows the previous list while it waits. The backoff schedule is in
  [Limits](limits.md#shelves).
- The host resolves `tmdb-id` first, then `tvdb-id` for a TV show. A ref with
  only `imdb-id` is dropped.
- `reason` is plain text. The host collapses it to one line and clips it
  ([Limits](limits.md#shelves)).
- The host drops titles that do not resolve, that are already in the library,
  that someone requested, that this user dismissed or that the user's
  restrictions do not allow, and drops duplicates. It takes the title, year and
  poster from its own metadata, never from the plugin.
- It resolves a bounded number of candidates per fill, in the order returned,
  and keeps the previous list when too few survive. Both numbers are in
  [Limits](limits.md#shelves).

### What a fill may do

A fill acts as the shelf's user and may only read.

| Function | Notes |
|----------|-------|
| [`search`](host-functions.md#search) | With `data:search`. |
| [`data-list`](host-functions.md#data-list) | With `data:read`. Scoped to the user: the same projections that user would see. |
| [`data-read`](host-functions.md#data-read) | With `data:read`. Reads as the user. |
| [`http-request`](host-functions.md#http-request) | With `net:http`. Gets the page network budget ([Limits](limits.md#network)). |
| [`connection-request`](host-functions.md#connection-request), [`link-request`](host-functions.md#link-request) | With `users:connections` and `net:http`. Outbound calls authenticated with a stored token, gated by grants. They do not write to Mydia. |
| The store functions ([`kv-get`](host-functions.md#kv-get) and the rest) | With `state:kv`. The plugin's own store stays writable. Use per-user keys. |

Every function that changes the user's data is refused during a fill and
returns `denied`, whatever the plugin has been granted:

- The functions that return a `write-outcome`: `media-add`,
  `collection-create`, `collection-update`, `collection-add-items`,
  `collection-remove-items`, `mark-watched-state` and `add-favorite`.
- The sync writes: `ensure-watched`, `set-watch-state` and `ensure-favorite`.

A fill runs against the plugin's default instance. A `multi_instance` plugin has
none, so the instance-scoped functions (the store functions and
`link-request`) return `not-found` during a fill. A fill runs under the page
timeout ([Limits](limits.md#runtime)). A failing shelf is listed on the
plugin's row in Admin > System > Plugins, with the last error the plugin
returned.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:501-535,695-699; lib/mydia/plugins/shelves.ex; lib/mydia/plugins/shelves/verifier.ex; lib/mydia/plugins/page_context.ex:9-42 -->
