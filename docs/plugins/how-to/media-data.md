# Cookbook

Practical recipes for common plugin tasks. Each one is self-contained: a goal,
the code, and a note on why it works. They assume the [quickstart](../index.md)
crate layout and build on the same typed `Event` handler.

Most recipes parse JSON out of the event. The examples use `serde_json` because
its indexing returns `Null` for missing keys instead of panicking, which keeps
the snippets short and safe. Add it to `Cargo.toml`:

```toml
[dependencies]
mydia-plugin-sdk = { git = "https://github.com/getmydia/mydia", branch = "master" }
serde_json = "1"
```

!!! tip "Keeping the component small"
    Any JSON crate works. If binary size matters, the bundled notifier uses
    [`tinyjson`](https://crates.io/crates/tinyjson) instead. Note that its
    indexing panics on a missing key, so reach for `.get(...)` and pattern
    matching rather than `value["key"]`.

## Post a notification when media is added

**Goal:** when a movie or show is added, POST a message to a webhook.

First, subscribe to the event and request the HTTP host in your
[manifest](../reference/manifest.md):

```json
{
  "slug": "added-notifier",
  "name": "Added Notifier",
  "version": "0.1.0",
  "capabilities": {
    "events:subscribe": ["media_item.added"],
    "net:http": ["example.com"]
  }
}
```

Then handle the event and send the request:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{Event, OutboundRequest};

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    let body = format!(r#"{{"text":"New media: {}"}}"#, evt.event);

    let resp = host::http_request(&OutboundRequest {
        url: "https://example.com/hook".into(),
        method: "POST".into(),
        headers: vec![("content-type".into(), "application/json".into())],
        body: Some(body),
    })
    .map_err(|e| format!("request failed: {e:?}"))?;

    Ok(format!(r#"{{"delivered":{},"status":{}}}"#, resp.ok, resp.status))
}
```

`host::http_request` is gated by your `net:http` grant. The host re-validates
the URL host against your allowlist and runs an SSRF check on every call, so a
request to a host you did not declare is denied.

!!! warning "`net:http` hosts are exact, no wildcards"
    List the exact hostnames you contact (`example.com`, `discord.com`). A
    wildcard subdomain would be a data-exfiltration channel, so the host refuses
    them.

## Send to Discord, ntfy, or a custom webhook

**Goal:** shape the request body for a specific notification service. The body
is just a string, so you build whatever the target expects.

=== "Discord"

    Discord webhooks take a JSON payload with `content` and optional `embeds`:

    ```rust
    let payload = format!(
        r#"{{"content":"{title} was added","embeds":[{{"title":"{title}"}}]}}"#,
        title = title
    );

    host::http_request(&OutboundRequest {
        url: webhook_url,
        method: "POST".into(),
        headers: vec![("content-type".into(), "application/json".into())],
        body: Some(payload),
    })
    ```

=== "ntfy"

    ntfy takes a plain-text body; the topic is in the URL path and metadata
    rides in headers:

    ```rust
    host::http_request(&OutboundRequest {
        url: ntfy_url, // e.g. https://ntfy.sh/my-topic
        method: "POST".into(),
        headers: vec![
            ("content-type".into(), "text/plain".into()),
            ("title".into(), title.clone()),
            ("priority".into(), "4".into()),
        ],
        body: Some(format!("{title} was added")),
    })
    ```

=== "Custom"

    Any webhook: set the method, headers, and body yourself.

    ```rust
    host::http_request(&OutboundRequest {
        url: webhook_url,
        method: "PUT".into(),
        headers: vec![
            ("content-type".into(), "application/json".into()),
            ("x-source".into(), "mydia".into()),
        ],
        body: Some(custom_body),
    })
    ```

The bundled [webhook notifier](https://github.com/getmydia/mydia/tree/master/plugins/webhook_notifier)
implements all three targets behind one operator setting. Read its `src/lib.rs`
for a full worked example, including templated bodies and query params.

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

## Build a two-way sync plugin

**Goal:** keep mydia's watched state in sync with a third-party service per user,
on a schedule and reactively: the shape the bundled **Simkl** plugin
(`plugins/simkl_sync`) implements. Read its `src/lib.rs` for the complete, tested
version; this recipe is the skeleton and the invariants that matter.

The surfaces a sync plugin uses:

- `users:connections` + a manifest `connection` descriptor: the host runs the
  OAuth flow and holds each user's token; you get `connections-list` (identity +
  status) and `connection-request` (authenticated calls, token injected
  host-side).
- `schedule:interval` + `on-schedule`: a periodic full sync.
- `events:subscribe: ["playback.finished"]` (react to a fresh local watch).
- `state:kv`: watermarks, cursors, and an echo-guard set, **keyed per
  connection** under `conn/<connection-id>/...` so reconnecting a different
  account starts clean.
- `data:read playback_progress` + `surfaces:write playback:watched`: read what
  the user watched locally; mark what the service says they watched.

```rust
fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    let mut invalid = Vec::new();
    for conn in host::connections_list().unwrap_or_default() {
        match sync_one(&conn) {
            Ok(()) => {}
            Err(Unauthorized) => invalid.push(conn.user_id.clone()), // a 401
            Err(_) => {}
        }
    }
    // The host marks these users' connections errored (and ProfileLive offers
    // reconnect). Only users who actually hold a connection are flipped.
    Ok(format!("{{\"connections_invalid\":{:?}}}", invalid))
}
```

Three invariants make a sync correct under interruption (the host kills a run on
wall-clock; there is no fuel metering):

1. **Pull checkpoints before applying.** Before you `ensure-watched` a pulled
   item, write its key into the durable pulled-set (`kv-set`). A kill after the
   checkpoint keeps the item out of the push even though the local write hasn't
   landed; the next run re-applies it (`ensure-watched` is idempotent).
2. **Push is at-least-once.** `kv-set` the pending batch before you POST, clear
   it after. A kill in between re-sends next run: a duplicate history entry is
   benign; a lost watch is not.
3. **Never echo.** An item you just pulled from the service must not be pushed
   back. Exclude anything in the pulled-set from the push batch.

Keep watermarks anchored to the **service's** timestamps (never local `now()`),
per user, per direction, so a clock skew or a re-run never re-syncs the world.

A reactive `playback.finished` handler (origin `player` only: your own
write-backs are already suppressed) can push that single watch immediately; the
scheduler's single-flight serializes it against a running sync so your KV state
never interleaves.

## Test without a host

**Goal:** unit-test your handler logic with `cargo test`, no Wasm build and no
running Mydia.

Because the handler is plain Rust, you call it directly:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use mydia_plugin_sdk::types::Event;

    fn event(kind: &str, metadata_json: &str) -> Event {
        Event {
            event: kind.into(),
            category: None,
            severity: None,
            actor_type: None,
            actor_id: None,
            resource_type: None,
            resource_id: None,
            metadata_json: metadata_json.into(),
        }
    }

    #[test]
    fn handles_added() {
        let evt = event("media_item.added", r#"{"config":{"webhook_url":"https://example.com/h"}}"#);
        assert!(on_event(evt).is_ok());
    }
}
```

The host functions (`http_request`, `data_read`) only exist in the Wasm
component, so a test that builds for the native target cannot link them
directly. Keep your testable logic in plain functions, and wrap the host calls
behind a thin shim that is compiled out off-Wasm:

```rust
#[cfg(target_arch = "wasm32")]
fn send(req: &OutboundRequest) -> Option<mydia_plugin_sdk::types::OutboundResponse> {
    mydia_plugin_sdk::host::http_request(req).ok()
}

#[cfg(not(target_arch = "wasm32"))]
fn send(_req: &OutboundRequest) -> Option<mydia_plugin_sdk::types::OutboundResponse> {
    None // tests exercise the request-building logic, not the wire call
}
```

This is exactly how the bundled notifier stays fully unit-tested. Its `src/lib.rs`
is worth reading for the pattern at scale.

## The dev loop

**Goal:** rebuild a plugin and load the new bytes into a running Mydia without a
restart.

Mydia reads an **override directory** (`PLUGINS_OVERRIDE_DIR`) as the
highest-precedence source of plugin bytes. Drop a `<slug>.wasm` there and it
shadows the installed copy; re-activating the plugin picks it up live. The loop:

```bash
# 1. Build the component.
cargo build --release --target wasm32-wasip2

# 2. Copy it into the override dir, named by your manifest slug.
#    (hyphen or underscore both resolve)
cp target/wasm32-wasip2/release/my_plugin.wasm "$PLUGINS_OVERRIDE_DIR/my-plugin.wasm"

# 3. Re-activate the plugin (toggle it in the admin UI), then trigger an event.
```

So the cycle is `edit -> build -> copy -> re-activate -> test`. The plugin must
already be installed (its manifest seeded) so the host knows its capabilities;
the copy only refreshes the Wasm bytes.

!!! tip "Shortcut for repo contributors"
    If you have the Mydia repo checked out, `native/mydia_plugin_sdk/sideload.sh`
    wraps steps 1 and 2 into one command:
    `PLUGINS_OVERRIDE_DIR=... native/mydia_plugin_sdk/sideload.sh path/to/crate --name my-plugin`.
    External plugin authors who pull the SDK as a dependency will not have this
    script, so the manual build-and-copy above is the canonical path.
