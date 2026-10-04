# Manifest

Every plugin ships a JSON manifest declaring its identity, the capabilities it
wants, and any operator-editable settings. The host parses and validates it
when the plugin is installed, sideloaded or discovered. A manifest that fails
validation is rejected with the error named below. Parsing confers nothing: the
grant is stored separately (see [Capabilities](capabilities.md#grants-and-approval)).

## A complete manifest

```json
{
  "slug": "ping-notifier",
  "name": "Ping Notifier",
  "version": "1.1.0",
  "description": "Posts a notification when media is added or a download completes.",
  "author": "Example",
  "min_host_version": "0.16.0",
  "capabilities": {
    "events:subscribe": ["media_item.added", "download.completed"],
    "net:http": ["discord.com"],
    "data:read": ["media_item"]
  },
  "settings_schema": [
    { "key": "target", "type": "enum", "label": "Target service",
      "options": ["discord", "ntfy", "custom"] },
    { "key": "webhook_url", "type": "url", "label": "Webhook / server URL",
      "hint": "The full URL notifications are posted to.", "grants_host": true },
    { "key": "ntfy_priority", "type": "string", "label": "Priority (1-5)",
      "visible_when": { "target": "ntfy" } }
  ]
}
```

## Top-level fields

| Field | Type | Required | Default | Rules |
|-------|------|----------|---------|-------|
| `slug` | string | yes | none | Stable identifier. Must not be blank. Hyphenated by convention (`webhook-notifier`); the host does not check the format. |
| `name` | string | yes | none | Name shown in the admin UI. Must not be blank. |
| `version` | string | yes | none | The plugin's own version. Must not be blank. The host compares versions as semantic versions when both parse, and as strings otherwise. |
| `description` | string | no | none | One-line summary shown in the UI. |
| `author` | string | no | none | Plugin author. |
| `entrypoint` | string | no | `"handle"` | Accepted and ignored. The host calls the guest's [exports](guest-exports.md) by name, so this value selects nothing. |
| `delivery` | string | no | `"inline"` | Read for plugins bundled with Mydia only: `durable` (an Oban job, retried, at-least-once) or `inline` (synchronous, not retried). Any other value becomes `inline`. Plugins installed from an index or sideloaded always run `inline`. |
| `min_host_version` | string | no | none | The lowest Mydia release that can run the plugin. A semantic version, or the manifest is rejected. The rules are in [What the host-version floor is for](../explanation/plugin-model.md#what-the-host-version-floor-is-for). |
| `multi_instance` | boolean | no | `false` | `true` lets operators add several instances, each with its own settings, store, links and schedule. Any non-boolean value is rejected. |
| `category` | string | no | none | Where the host lists instances. The only value is `media_server`, which puts them on Admin > Media servers. Any other value is rejected. |
| `setup` | boolean | no | `false` | `true` when the plugin exports [`setup`](guest-exports.md#setup): the host then creates instances through the setup wizard instead of the plain settings form. Any non-boolean value is rejected. |
| `capabilities` | object | yes | none | Must be a non-empty object. At least one of `events:subscribe`, `surfaces:page` or `surfaces:shelf` must be present. The classes, values and rules are in [Capabilities](capabilities.md). Events are in [Events](events.md). |
| `settings_schema` | array | no | `[]` | Operator-editable fields. See [Settings schema](#settings-schema). |
| `connection` | object | no | none | Per-user account link. See [Connection descriptor](#connection-descriptor). |
| `schedule` | object | no | none | Fixed-interval schedule. Requires `schedule:interval`. See [Schedule descriptor](#schedule-descriptor). |
| `page` | object | when `surfaces:page` | none | Navigation entry. Required with `surfaces:page` and rejected without it. See [Page descriptor](#page-descriptor). |
| `shelves` | array | when `surfaces:shelf` | `[]` | Home shelves. Required with `surfaces:shelf`, and a non-empty list is rejected without it. See [Shelves](#shelves). |

Fields the host does not know are ignored.

## Settings schema

`settings_schema` is an array of field objects. Mydia renders them as a form in
the admin UI. The operator's values reach the guest under the `config` key of
the event's `metadata_json` (see
[Read operator settings](../how-to/media-data.md#read-operator-settings)).
Keys must be unique across the array.

### Field types

| `type` | UI | Use for |
|--------|----|---------|
| `string` | single-line text | short values, IDs, comma-separated lists |
| `text` | multi-line text | templates, long bodies |
| `url` | URL input | endpoints; pair with `grants_host` |
| `secret` | masked input | tokens and passwords |
| `enum` | select | a fixed set of choices via `options` |

Any other `type` is rejected.

### Field attributes

| Attribute | Type | Applies to | Rules |
|-----------|------|------------|-------|
| `key` | string | all | Required, not blank, unique within the schema. The key your handler reads. |
| `type` | string | all | Required. One of the types above. |
| `label` | string | all | Form label shown to the operator. |
| `hint` | string | all | Help text shown under the field. A non-empty string when present. Keep `label` short and put examples and caveats here. |
| `required` | boolean | all | Accepted and ignored by the settings form: the field is not marked and an empty value is not rejected. Validate in your handler. (Setup wizard fields, which a guest returns from `setup`, do enforce their own `required`.) |
| `options` | array of strings | `enum` | Required for `enum`: a non-empty list of non-blank strings. |
| `grants_host` | boolean | `url` only | See [Host-granting fields](#host-granting-fields). Rejected on any other type. |
| `allow_private` | boolean | `url` with `grants_host` | See [Private network hosts](#private-network-hosts). Rejected elsewhere. |
| `visible_when` | object | all | See [Conditional visibility](#conditional-visibility). |

### Host-granting fields

A `url` field with `"grants_host": true` lets a plugin contact a host the
operator chooses. When the operator saves the value, the host takes its
hostname and adds it to the plugin's effective `net:http` allowlist. The guest
computes nothing.

```json
{ "key": "webhook_url", "type": "url", "label": "Webhook / server URL",
  "grants_host": true }
```

### Private network hosts

A host-granting field may also set `"allow_private": true`. The operator's
value is then allowed to resolve to a private address (a LAN service such as
`http://ollama.lan:11434`), which the outbound gate refuses by default.

```json
{ "key": "base_url", "type": "url", "label": "API base URL",
  "grants_host": true, "allow_private": true }
```

While the field has a value, the host derives a `net:private` grant for that
host next to its `net:http` grant. You never declare `net:private` in the
manifest. While the field is empty no `net:private` grant exists.

### Conditional visibility

`visible_when` is an object mapping a controlling field's key to a string or a
non-empty list of strings. The field is shown only while the controlling field's
current value is one of them.

```json
{ "key": "ntfy_priority", "type": "string", "label": "Priority (1-5)",
  "visible_when": { "target": "ntfy" } }
```

- The object must not be empty, and every value must be a string or a non-empty
  list of strings.
- Every key must name a sibling field in the same `settings_schema`, or the
  manifest is rejected.
- Visibility is presentation only. The host does not enforce it.

## Page descriptor

`page` names the navigation entry for a plugin page. It is required with the
`surfaces:page` capability and rejected without it.

```json
"page": { "title": "Assistant", "icon": "hero-sparkles" },
"capabilities": { "surfaces:page": [] }
```

| Field | Type | Rules |
|-------|------|-------|
| `title` | string | Required. 1 to 40 characters, not blank. |
| `icon` | string | Required. One of the names below. Any other name is rejected. |

Allowed icons: `hero-sparkles`, `hero-bookmark`, `hero-book-open`,
`hero-chat-bubble-left-right`, `hero-film`, `hero-tv`, `hero-star`,
`hero-heart`, `hero-bolt`, `hero-fire`, `hero-globe-alt`, `hero-beaker`,
`hero-puzzle-piece`, `hero-rectangle-stack`, `hero-queue-list`,
`hero-list-bullet`, `hero-clipboard-document-list`, `hero-chart-bar`,
`hero-magnifying-glass`, `hero-light-bulb`, `hero-cpu-chip`,
`hero-wrench-screwdriver`, `hero-cog-6-tooth`, `hero-folder`, `hero-tag`.

To build a page, see [Serve a page](../how-to/pages.md).

## Shelves

`shelves` lists the shelves the host asks the plugin to fill through its
[`fill-shelf`](guest-exports.md#fill-shelf) export. It is required with
`surfaces:shelf`, and a non-empty list is rejected without it.

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

| Field | Type | Required | Rules |
|-------|------|----------|-------|
| `key` | string | yes | Matches `[a-z][a-z0-9_]{0,31}`. Unique within the plugin. |
| `title` | string | yes | 1 to 40 characters, not blank. The shelf heading. |
| `placement` | string | yes | `home`. |
| `scope` | string | yes | `user`. |
| `ttl_seconds` | integer | yes | 3600 to 2592000. |
| `refresh_on` | array of strings | no | Event types from the [catalog](events.md#event-catalog). Defaults to `[]`. |

At most four shelves. The other shelf limits and the refresh rules are in
[limits](limits.md#shelves). To build one, see [Fill a shelf](../how-to/shelves.md).

## Schedule descriptor

`schedule` opts the plugin into the host's fixed-interval tick, which calls the
[`on-schedule`](guest-exports.md#on-schedule) export. It requires the
`schedule:interval` capability.

```json
"schedule": { "interval_minutes": 30 },
"capabilities": { "schedule:interval": [] }
```

| Field | Type | Rules |
|-------|------|-------|
| `interval_minutes` | integer | Required. At least 5. |

A `schedule` that is not an object, a missing or non-integer interval, an
interval below 5, and a schedule without `schedule:interval` are all rejected.
Timeouts and tick behaviour are in [limits](limits.md#runtime) and
[Guest exports](guest-exports.md#on-schedule).

## Connection descriptor

`connection` describes a per-user third-party account the host links on the
plugin's behalf. Users connect at `/integrations`. For the `oauth_device` type
the host runs the OAuth device (PIN) flow end to end; the guest never executes
during connect and never sees the token. The plugin reaches the linked account
with [`connection-request`](host-functions.md#connection-request).

```json
"connection": {
  "type": "oauth_device",
  "code_url": "https://api.example.com/oauth/pin?client_id={client_id}",
  "poll_url": "https://api.example.com/oauth/pin/{user_code}?client_id={client_id}",
  "verification_url": "https://example.com/pin",
  "client_id": "your-public-embeddable-client-id"
}
```

| Field | Type | Required | Default | Rules |
|-------|------|----------|---------|-------|
| `type` | string | yes | none | `oauth_device` or `none`. `none` declares only `auth_header`, with no device flow. |
| `code_url` | string | `oauth_device` | none | URL template the host requests to start the flow. |
| `poll_url` | string | `oauth_device` | none | URL template the host polls. |
| `verification_url` | string | no | none | The page the user is sent to. |
| `client_id` | string | no | none | The public, embeddable client id. An operator can override it with a `client_id` setting. |
| `auth_header` | string | no | `"Authorization: Bearer {token}"` | `"Name: value"`, where `value` contains `{token}`. The name must be a valid HTTP header name. |
| `method` | string | no | `"GET"` | `GET` or `POST`. Applies to the `code_url` and `poll_url` requests. |
| `headers` | object | no | `{}` | Map of header name to string value. Applies to the `code_url` and `poll_url` requests. |

- `{client_id}` and `{user_code}` in the URLs are substituted by the host.
- `code_url`, `poll_url` and `verification_url` must each be a valid URL whose
  host is listed in `net:http`, or the manifest is rejected.
- A `connection` that is not an object is rejected.

## Host-version floor

`min_host_version` is described in the [top-level fields](#top-level-fields)
table. The reasoning and the rules for how Mydia applies it are in
[What the host-version floor is for](../explanation/plugin-model.md#what-the-host-version-floor-is-for).
