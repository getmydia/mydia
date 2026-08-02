# Work with Media and Event Data

Practical recipes for reading data, settings, and events inside a handler.
Each one is self-contained: a goal, the code, and a note on why it works. They
assume the [tutorial](../tutorial/write-your-first-plugin.md)'s crate layout
and build on the same typed `Event` handler.

Most recipes parse JSON out of the event. The examples use `serde_json` because
its indexing returns `Null` for missing keys instead of panicking, which keeps
the snippets short and safe. Add it to `Cargo.toml`:

```toml
[dependencies]
mydia-plugin-sdk = { git = "https://github.com/getmydia/mydia", tag = "v0.13.0-beta.1" }
serde_json = "1"
```

!!! tip "Keeping the component small"
    Any JSON crate works. If binary size matters, the bundled notifier uses
    [`tinyjson`](https://crates.io/crates/tinyjson) instead. Note that its
    indexing panics on a missing key, so reach for `.get(...)` and pattern
    matching rather than `value["key"]`.

## Enrich an event with media details

**Goal:** the event tells you *what* happened and which resource it concerns,
but not much about it. Pull the curated media record to get the title,
overview, year, and more.

Request the `data:read` capability for the `media_item` namespace:

```json
"capabilities": {
  "events:subscribe": ["media_item.added"],
  "data:read": ["media_item"]
}
```

Then read the projection using the event's `resource_id`:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{DataRequest, Event, ReadResult};

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    // The resource this event concerns, e.g. resource_type "media_item".
    let id = evt.resource_id.clone().unwrap_or_default();

    if evt.resource_type.as_deref() == Some("media_item") {
        match host::data_read(&DataRequest { namespace: "media_item".into(), id }) {
            Ok(ReadResult::MediaItem(item)) => {
                host::log("info", &format!("enriched: {} ({:?})", item.title, item.year));
                // item.title, item.overview, item.genres, item.poster_path, ...
            }
            Err(e) => host::log("warn", &format!("data_read failed: {e:?}")),
        }
    }

    Ok(r#"{"ok":true}"#.into())
}
```

`data_read` returns a **curated, read-only projection**, never the raw row or
any secrets. The `media_item` projection includes `title`, `original_title`,
`year`, `overview`, `tagline`, `genres`, `runtime`, `rating`, `poster_path`,
the external IDs (`tmdb_id`, `tvdb_id`, `imdb_id`), and more. See the
[Reference](../reference/host-api.md#host-functions) for the full field list.

## Read operator settings

**Goal:** let the operator configure your plugin (a webhook URL, an API token, a
choice of target), and read those values at runtime.

Declare the fields in your manifest's `settings_schema` (see
[Manifest & Settings](../reference/manifest.md)). At runtime, the operator's configured
values arrive inside `evt.metadata_json` under the `config` key, alongside the
event's own detail under `metadata`:

```rust
use mydia_plugin_sdk::types::Event;
use serde_json::Value;

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    let root: Value = serde_json::from_str(&evt.metadata_json)
        .map_err(|e| format!("bad metadata_json: {e}"))?;

    // Indexing a missing key yields Null, so this never panics.
    let webhook_url = root["config"]["webhook_url"].as_str().unwrap_or_default();

    if webhook_url.is_empty() {
        return Err("no webhook_url configured".into());
    }

    // ... use webhook_url ...
    Ok(r#"{"ok":true}"#.into())
}
```

The typed `Event` envelope stays stable while arbitrary per-event detail and the
operator's settings ride in `metadata_json` as a JSON object. Parse it once and
read what you need.

## Call an authenticated API

**Goal:** send a bearer token (stored as a `secret` setting) on an outbound
request.

Mark the field as `secret` in your manifest so the admin UI masks it:

```json
"settings_schema": [
  { "key": "api_token", "type": "secret", "label": "API token", "required": true }
]
```

Read it from `config` and attach it as a header:

```rust
let token = root["config"]["api_token"].as_str().unwrap_or_default();

host::http_request(&OutboundRequest {
    url: "https://api.example.com/notify".into(),
    method: "POST".into(),
    headers: vec![
        ("content-type".into(), "application/json".into()),
        ("authorization".into(), format!("Bearer {token}")),
    ],
    body: Some(payload),
})
```

Secrets are stored and injected by the host; they never appear in your plugin's
bytes or logs. Avoid logging them yourself.

## Act on only the events you care about

**Goal:** one plugin subscribes to several events but handles each differently,
and ignores the rest.

Subscribe to each event in the manifest, then branch on `evt.event`:

```rust
#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    match evt.event.as_str() {
        "media_item.added" => handle_added(&evt),
        "download.completed" => handle_download(&evt),
        // Subscribed in the manifest but nothing to do here.
        _ => Ok(r#"{"skipped":true}"#.into()),
    }
}
```

The host only delivers events you subscribed to, but matching on `evt.event`
keeps a multi-purpose plugin readable and lets you skip events cheaply. The v1
catalog is `media_item.added`, `media_item.updated`, `media_item.removed`,
`media_file.imported`, `download.completed`, and `download.failed`.

## Report a result the host records

**Goal:** tell the host what happened so it shows up in the plugin's activity.

The handler returns `Result<String, String>`:

- `Ok(json)` records a success. Return a small JSON object the host stores, by
  convention something like `{"delivered":true,"status":204}`.
- `Err(message)` is surfaced as a plugin error in the UI and logs.

Handle `HostError` from host calls rather than letting them bubble as panics:

```rust
use mydia_plugin_sdk::types::HostError;

match host::http_request(&req) {
    Ok(resp) if resp.ok => Ok(format!(r#"{{"delivered":true,"status":{}}}"#, resp.status)),
    Ok(resp) => Ok(format!(r#"{{"delivered":false,"status":{}}}"#, resp.status)),
    Err(HostError::Denied(msg)) => Err(format!("capability denied: {msg}")),
    Err(HostError::Network(msg)) => Err(format!("network error: {msg}")),
    Err(e) => Err(format!("host error: {e:?}")),
}
```

`HostError` carries a human-readable detail in every variant: `Denied`,
`InvalidRequest`, `NotFound`, `Network`, and `Internal`. The host never lets a
guest bypass a capability gate, so always handle a possible `Denied`.

Use `host::log("debug" | "info" | "warn" | "error", message)` for diagnostics
that should land in the plugin's activity log. It is ungated and fire-and-forget.

## Next steps

- [Send notifications](notifications.md) - push what you read here to an external service
- [Build a two-way sync](two-way-sync.md) - the same reads, plus per-user connections and write-back
- [Test and iterate](test-and-iterate.md) - the build and reload loop
