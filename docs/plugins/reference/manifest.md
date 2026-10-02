# Manifest & Settings

Every plugin ships a JSON manifest declaring its identity, the events it
subscribes to, the capabilities it wants, and any operator-editable settings.
This page is a practical reference, using the bundled webhook notifier
(`priv/plugins/webhook_notifier.json`) as the worked example.

## A complete manifest

```json
{
  "slug": "webhook-notifier",
  "name": "Webhook Notifier",
  "version": "1.1.0",
  "description": "Posts a notification when media is added or a download completes.",
  "author": "Mydia",
  "entrypoint": "handle",
  "delivery": "durable",
  "capabilities": {
    "events:subscribe": ["media_item.added", "download.completed"],
    "net:http": ["discord.com"],
    "data:read": ["media_item"]
  },
  "settings_schema": [
    { "key": "target", "type": "enum", "label": "Target service", "required": true,
      "options": ["discord", "ntfy", "custom"] },
    { "key": "webhook_url", "type": "url", "label": "Webhook / server URL",
      "required": true, "grants_host": true }
  ]
}
```

## Top-level fields

| Field | Required | Notes |
|-------|----------|-------|
| `slug` | yes | Stable identifier, hyphenated (e.g. `webhook-notifier`). Also the override filename stem. |
| `name` | yes | Human-readable name shown in the admin UI. |
| `version` | yes | Semantic version of the plugin. |
| `description` | no | One-line summary shown in the UI. |
| `author` | no | Plugin author. |
| `entrypoint` | no | Exported handler name. Defaults to the SDK handler; leave unset unless you know you need it. |
| `delivery` | no | `durable` (enqueues an Oban job, retried, at-least-once) or `inline` (runs synchronously, not retried). Defaults to `inline`. Any other value, including a typo, silently becomes `inline`. |
| `min_host_version` | no | Lowest Mydia version that can run this plugin. See below. |
| `multi_instance` | no | `true` lets operators add several instances, each with its own settings, store, links and schedule. Default `false`. |
| `category` | no | Where the host lists instances. `media_server` puts them on Admin > Media servers. |
| `setup` | no | `true` when the plugin exports `setup`; the host then creates instances through the setup wizard instead of the plain settings form. Default `false`. |
| `capabilities` | yes | What the plugin subscribes to and is allowed to do. See below. |
| `settings_schema` | no | Operator-editable configuration fields. See below. |

## Capabilities

Capabilities are **deny-by-default** and enforced server-side on every host
call. The manifest *declares* what the plugin wants; for a third-party plugin
the operator approves that declaration at install time. A plugin can never widen
its own grant at runtime.

| Capability | Meaning |
|------------|---------|
| `events:subscribe` | The event types the plugin reacts to. Each must be in the catalog. Required unless the plugin declares `surfaces:page` or `surfaces:shelf`, so a page-only or shelf-only plugin can omit it. |
| `net:http` | The exact hostnames the plugin may contact. No wildcards. |
| `data:read` | Read namespaces the plugin may query (`media_item`, `playback_progress`, `library_item`, plus the page-only `media_request`, `download`, `collection`, `watch_history`). Returns a curated, read-only projection. |
| `data:search` | Lets a page call the `search` host function against the acting user's library or the metadata catalog. Takes an empty list. |
| `surfaces:page` | The plugin serves its own page at `/plugins/<slug>/app/`, shown in the navigation. Takes an empty list and requires a [`page` descriptor](#page-descriptor). See [Serve a page](../how-to/pages.md). |
| `surfaces:write` | Curated write surfaces. Value vocabulary: `playback:watched`, `collections:favorite`, `media:add`, `collections:write`. See [write surfaces](#write-surfaces). |
| `state:kv` | A small per-plugin key/value store that survives across invocations (watermarks, cursors, dedupe sets). |
| `users:connections` | Per-user third-party connections the host holds on the plugin's behalf. **Cross-user**: see below. |
| `schedule:interval` | Lets the plugin run on a fixed interval via `on-schedule`. Paired with the `schedule` descriptor. |
| `surfaces:shelf` | Fill shelves the host renders. Requires `shelves`. See [Shelves](#shelves). Takes an empty list. |

### Write surfaces

| Value | Host functions | Available to |
|-------|----------------|--------------|
| `playback:watched` | `ensure-watched` (connected users), `mark-watched-state` (page) | events and pages |
| `collections:favorite` | `ensure-favorite` (connected users), `add-favorite` (page) | events and pages |
| `media:add` | `media-add` | pages only |
| `collections:write` | `collection-create`, `collection-update`, `collection-add-items`, `collection-remove-items` | pages only |

Page writes act as the signed-in user, are journaled, and may need the user's
confirmation first. See [Pages and writes on a user's behalf](../explanation/plugin-model.md#pages-and-writes-on-a-users-behalf).

### Page-only `data:read` namespaces

`media_request`, `download`, `collection` and `watch_history` can only be listed from a page
(`on-http`). In a page call every namespace, including `media_item`,
`library_item` and `playback_progress`, is read as the acting user, so a page
never sees more than the person using it. `media_request` and `collection` are
the user's own rows, and `download` lists active downloads for items the acting
user requested (even administrators see only those). Outside a page these
namespaces are not available. `watch_history` returns the user's own
`playback-progress` rows newest first by `last-watched-at`, with an episode's
`media-item-id` set to its show so a page can resolve titles with `data-read`.

The event catalog for `events:subscribe`:

- `media_item.added`
- `media_item.updated`
- `media_item.removed`
- `media_file.imported`
- `download.completed`
- `download.failed`
- `playback.started`
- `playback.progressed` (sampled): the host emits at most one per 5% completion bucket, so a burst of position updates yields a single event.
- `playback.paused`: in the catalog; not yet emitted (no player pause signal).
- `playback.finished`: the unwatched→watched edge (the 90% auto-mark, an explicit mark-watched, or a sync write).

Every `playback.*` event carries an `origin` in its metadata: `player` (a real client write), `sync:<provider>` (a media-server or Trakt import), or `plugin:<slug>` (a plugin write-back). The dispatcher never delivers an event back to the plugin that originated it, so a plugin's own `ensure-watched` writes do not echo to itself.

!!! warning "`users:connections` and `data:read playback_progress` are cross-user"
    These are the platform's first cross-user capabilities. The approval line
    states plainly that the plugin can read connected users' linked accounts and
    watch history and mark items watched on their behalf. Access is **consent-
    scoped**: a user is only visible to the plugin after they click *Connect* on
    their profile. `data-list playback_progress` returns rows only for connected
    users, and `ensure-watched` is rejected for a user without an active
    connection. The same consent gate applies to `ensure-favorite`.

!!! warning "Third-party manifest revisions need re-approval"
    A plugin installed from an index or remote package cannot widen its grant.
    New capability classes, hosts, or events remain denied until an administrator
    reviews and re-approves the revised manifest in **Admin > System > Plugins**.

!!! note "Bundled system plugins follow the host release"
    Plugins shipped in Mydia's `priv/plugins/` directory are trusted as part of
    the host release. First discovery grants and enables them automatically.
    Later releases replace their grants with the exact effective capabilities in
    the shipped manifest while preserving the administrator's enabled/disabled
    choice and settings.

    Because the host release is the source of truth, Remove and Revoke are not
    final for a bundled plugin: the next reconciliation restores the
    release-declared capabilities, and Remove re-seeds the row approved and
    enabled. Disable is the control that persists across upgrades.

!!! warning "`net:http` is an exact-host allowlist"
    List each host you contact (`discord.com`, `api.example.com`). Wildcard
    subdomains are rejected because they would be a data-exfiltration channel.
    For services where the operator brings their own host (a self-hosted ntfy,
    a personal webhook), use a host-granting setting instead (see `grants_host`
    below) so you do not have to know the host in advance.

## Settings schema

`settings_schema` is an array of field definitions. Mydia renders them as a form
in the admin UI, and the operator's values arrive at runtime inside the event's
`metadata_json` under the `config` key (see
[Read operator settings](../how-to/media-data.md#read-operator-settings)).

### Field types

| `type` | UI | Use for |
|--------|----|---------|
| `string` | single-line text | short values, IDs, comma-separated lists |
| `text` | multi-line text | templates, long bodies |
| `url` | URL input | endpoints; pair with `grants_host` |
| `secret` | masked input | tokens, passwords (never logged, never in plugin bytes) |
| `enum` | select | a fixed set of choices via `options` |

### Field attributes

| Attribute | Applies to | Meaning |
|-----------|------------|---------|
| `key` | all | The config key your handler reads. |
| `label` | all | Form label shown to the operator. |
| `required` | all | **Not implemented.** Accepted in the manifest and then ignored: the form does not mark the field, and an empty value is not rejected. Validate in your handler instead. |
| `options` | `enum` | The allowed choices (array of strings). |
| `grants_host` | `url` | The host of the operator's value is added to the plugin's `net:http` allowlist at config time. |
| `visible_when` | all | Show the field only when another field has a given value. |

### Host-granting URL fields

A `url` field with `"grants_host": true` is how a plugin contacts a host the
operator chooses without hard-coding it. When the operator saves the value, the
host parses out its hostname and adds it to the plugin's effective `net:http`
allowlist. The plugin computes nothing; Mydia stays target-agnostic.

```json
{ "key": "webhook_url", "type": "url", "label": "Webhook / server URL",
  "required": true, "grants_host": true }
```

This is why the notifier can POST to any ntfy server or custom webhook the
operator points it at, while still declaring only `discord.com` statically.

### Conditional visibility

`visible_when` gates a field on another field's value, so the form only shows
what is relevant to the current selection:

```json
{ "key": "ntfy_priority", "type": "string", "label": "Priority (1-5)",
  "visible_when": { "target": "ntfy" } }
```

Here `ntfy_priority` only appears when the operator has set `target` to `ntfy`.

## Page descriptor

A plugin that declares `surfaces:page` must also declare a `page` descriptor,
and a `page` descriptor without `surfaces:page` is rejected. It names the
navigation entry:

```json
"page": { "title": "Assistant", "icon": "hero-sparkles" },
"capabilities": { "surfaces:page": [] }
```

- `title` is 1 to 40 characters.
- `icon` is one of a fixed set of Heroicons names (the host builds the CSS for
  a fixed set of icons ahead of time, so an arbitrary name would render blank):
  `hero-sparkles`, `hero-bookmark`, `hero-book-open`,
  `hero-chat-bubble-left-right`, `hero-film`, `hero-tv`, `hero-star`,
  `hero-heart`, `hero-bolt`, `hero-fire`, `hero-globe-alt`, `hero-beaker`,
  `hero-puzzle-piece`, `hero-rectangle-stack`, `hero-queue-list`,
  `hero-list-bullet`, `hero-clipboard-document-list`, `hero-chart-bar`,
  `hero-magnifying-glass`, `hero-light-bulb`, `hero-cpu-chip`,
  `hero-wrench-screwdriver`, `hero-cog-6-tooth`, `hero-folder`, `hero-tag`.
  Any other name is rejected when the manifest is parsed.

## Shelves

A plugin that declares `surfaces:shelf` must also declare a `shelves` list, and
a non-empty `shelves` list without `surfaces:shelf` is rejected. Each entry
describes one shelf the host asks the plugin to fill through its `fill-shelf`
export:

```json
"shelves": [
  {
    "key": "picks",
    "title": "Picked for you",
    "placement": "home",
    "scope": "user",
    "ttl_seconds": 86400,
    "refresh_on": ["playback.finished"]
  }
],
"capabilities": { "surfaces:shelf": [] }
```

| Field | Required | Bounds |
|-------|----------|--------|
| `key` | yes | Matches `[a-z][a-z0-9_]{0,31}`. Unique within the plugin. |
| `title` | yes | 1 to 40 characters. Shown as the shelf heading. |
| `placement` | yes | `home`. |
| `scope` | yes | `user`. The shelf is filled for, and shown to, one person. |
| `ttl_seconds` | yes | An integer from 3600 to 2592000. How long a fill lasts before the host asks again. |
| `refresh_on` | no | A list of event types from the [catalog](#capabilities). Defaults to `[]`. An event marks the shelf stale for the user it belongs to. |

A plugin may declare at most four shelves. Because a fill reads a person's
watch history, the approval screen flags `surfaces:shelf` as sensitive.

## Private network hosts

A `url` field with `grants_host: true` may also set `"allow_private": true`.
The operator's value is then allowed to resolve to a private address (a
LAN service such as `http://ollama.lan:11434`), which the outbound gate refuses
by default. `allow_private` is only accepted on `url` fields that also set
`grants_host`.

```json
{ "key": "base_url", "type": "url", "label": "API base URL",
  "grants_host": true, "allow_private": true }
```

When such a field has a value, the host derives a `net:private` grant for that
one host next to its `net:http` grant. You never declare `net:private` in the
manifest, and while the field is empty no `net:private` grant exists.

## Scheduled plugins

A plugin that needs a clock declares a `schedule` and the `schedule:interval`
capability. The host invokes its `on-schedule` export on a fixed interval:

```json
"schedule": { "interval_minutes": 30 },
"capabilities": { "schedule:interval": [] }
```

- `interval_minutes` is floored at **5 minutes**; a smaller value is rejected at
  parse.
- A schedule with no `schedule:interval` capability is rejected: the admin
  always sees the schedule at approval.
- Ticks are **non-reentrant**: if a previous run (scheduled, reactive, or
  inline) is still in flight the tick is a no-op, so work never piles up.
- `on-schedule` runs under a larger timeout budget than `on-event` (default
  60s). A run that fails backs off exponentially; a success resets the counter.
- A scheduled run may return a `connections_invalid` array in its JSON result;
  the host marks those users' connections `error` (only users who actually hold
  an active connection: a guest can't mass-error state).

## Connection descriptor

A plugin that links a per-user third-party account declares a `connection`
descriptor. The **host** runs the OAuth device (PIN) flow end to end from a
generic card on the user's profile; the guest never executes during connect and
never sees the token.

```json
"connection": {
  "type": "oauth_device",
  "code_url": "https://api.example.com/oauth/pin?client_id={client_id}",
  "poll_url": "https://api.example.com/oauth/pin/{user_code}?client_id={client_id}",
  "verification_url": "https://example.com/pin",
  "client_id": "your-public-embeddable-client-id"
}
```

- `code_url`, `poll_url`, and `verification_url` must all sit on a host declared
  in `net:http`, so the verification URL rendered in trusted UI can never be a
  phishing surface.
- `{client_id}` and `{user_code}` are substituted by the host. The embedded
  `client_id` is the public/embeddable id; an operator can override it via a
  `client_id` setting.
- The plugin reaches the connected account with `connection-request`, which
  attaches the bearer token host-side (see the [Reference](host-api.md)).

`auth_header` sets how the host attaches a link's token, as `"Name: value"`
with `{token}` in the value, for example `"X-Plex-Token: {token}"`. It
defaults to `"Authorization: Bearer {token}"`. `method` (`GET` or `POST`,
default `GET`) and `headers` (a string map) apply to the device flow's
`code_url` and `poll_url`. Set `"type": "none"` to declare only `auth_header`
without a device flow.

## Host-version floor

`min_host_version` (optional, a semantic version) declares the lowest Mydia
release your plugin supports. It is a Mydia release version, not a contract
version. If you rely on a capability, event, or contract feature added in a
specific release, set the floor to that release. Mydia refuses to activate an
index-installed plugin whose floor exceeds the running host, with a clear
`requires mydia >= X` message. Pre-release tags are ignored, so a
`0.16.0-beta.1` host meets a `0.16.0` floor. Development builds (`-dev`) meet any
floor, and plugins bundled with Mydia are not checked. Omit it if you have no
floor.

The plugin contract evolves additively: new functions, records, variant cases,
and optional fields are added without breaking existing plugins. Only a removal
or a signature change bumps the major ABI version. For the full contract and
versioning rules, see the [Reference](host-api.md#evolving-the-contract).
