# Host API Reference

The contract Mydia plugins run against: the event envelope and catalog, the
capability classes and their host functions, the scheduled-handler export, and
the manifest fields that govern versioning.

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
plugin can never widen its own grant. A manifest *declares* what it wants; the
operator approves it.

| Class | Meaning |
|-------|---------|
| `events:subscribe` | The event types the plugin reacts to (from the catalog above). Required. |
| `net:http` | The exact hostnames the plugin may contact. **No wildcards** (a wildcard subdomain is an exfiltration channel). A relative request against an instance connection needs `users:connections` only, because there is no hostname to grant. |
| `data:read` | Scoped read namespaces (`media_item`, `playback_progress`). The host returns a curated, read-only projection: never raw rows or secrets. |
| `surfaces:write` | Curated write surfaces. Vocabulary: `playback:watched` (mark items watched via `ensure-watched`), `connections` (register or update a connection via `connection-upsert`). |
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
let page = host::data_list(&ListRequest {
    namespace: "playback_progress".into(),
    cursor: None,
    updated_since: mark.clone(),
    limit: Some(200),
}).unwrap();
for item in page.items {
    if let ListItem::PlaybackProgress(p) = item { let _ = p.watched; }
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

Key guarantees:

- `ensure-watched` is **idempotent**: re-marking a watched item reports
  `already-watched` and emits no event.
- `data-list` cursors are opaque and request-local: walk them within one run,
  never persist them.
- `kv-set` is an engine-native upsert (last write wins); keys are opaque to the
  host. Keys under `conn/<connection-id>/...` are swept when that connection is
  removed.

### 1.3 host functions

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::ConnectionDraft;

// surfaces:write "connections": register or update a connection the guest
// discovered during onboarding. The host stores the secret; no read path ever
// returns it. Omit user_id for an instance-scoped service endpoint; set it for
// a per-user account link.
host::connection_upsert(&ConnectionDraft {
    label: "Living room".into(),
    base_urls: vec!["http://10.0.0.5:8096".into()],
    secret: "operator-token".into(),
    auth_kind: "header".into(),
    auth_key: Some("X-Emby-Token".into()),
    user_id: None,
    external_user_id: None,
    external_username: None,
}).ok();
```

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

### Connect handler

Add `on-connect` for interactive onboarding (declare a `connection` descriptor
with `"onboarding": "guest"` in the manifest):

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    ConnectDone, ConnectPending, ConnectRequest, ConnectResponse,
    ConnectionDraft, Event,
};

#[mydia_plugin_sdk::plugin(on_connect = on_connect)]
fn on_event(_evt: Event) -> Result<String, String> { Ok("{}".into()) }

fn on_connect(req: ConnectRequest) -> Result<ConnectResponse, String> {
    match req.step.as_str() {
        // Turn 1: the operator clicked Connect. Return Pending to show a code
        // and poll, Prompt to show a form or picker, or Done when nothing
        // interactive is needed.
        "start" => Ok(ConnectResponse::Pending(ConnectPending {
            message: "Enter this code at the provider".into(),
            code: Some("ABCD-1234".into()),
            verification_url: Some("https://provider.example/activate".into()),
            interval_ms: 2_000,
            state_json: "{}".into(),
        })),

        // Turn 2 (Pending path): the host re-invokes on interval_ms. Poll the
        // provider, then upsert the connection and finish.
        "poll" => {
            host::connection_upsert(&ConnectionDraft {
                label: "Discovered server".into(),
                base_urls: vec!["http://10.0.0.9:9999".into()],
                secret: "discovered-token".into(),
                auth_kind: "header".into(),
                auth_key: Some("X-Provider-Token".into()),
                user_id: None,
                external_user_id: None,
                external_username: None,
            })
            .map_err(|e| format!("{e:?}"))?;

            Ok(ConnectResponse::Done(ConnectDone {
                message: "Connected".into(),
            }))
        }

        // Turn 2 (Prompt path): the operator submitted the form the guest asked
        // for on the previous turn. input_json carries their answers.
        "submit" => {
            let _input: serde_json::Value =
                serde_json::from_str(&req.input_json).map_err(|e| e.to_string())?;
            // Validate, call connection_upsert, return Done or another Prompt.
            Ok(ConnectResponse::Done(ConnectDone {
                message: "Saved".into(),
            }))
        }

        other => Err(format!("unexpected step {other}")),
    }
}
```

The host drives a three-step state machine:

1. **`start`** - one invocation when the operator clicks Connect. Return
   `Pending` (show a code and poll), `Prompt` (show fields or choices), or
   `Done`.
2. **`poll`** - re-invoked on the `interval_ms` you returned from `Pending`.
   Use it to poll a provider until ready, then `connection-upsert` and return
   `Done`.
3. **`submit`** - re-invoked once when the operator submits a `Prompt` form.
   Read their answers from `input_json`, upsert if appropriate, return `Done`
   or another `Prompt`.

Each turn is a fresh invocation: carry state in `state_json` between turns.
Sessions expire after ten minutes. A plugin without `on-connect` uses the
manifest's static `fields` form instead.

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
so a `1.0` guest's `on-event` still resolves against a `1.3` host. Only a removal
or a signature change bumps the major version. Target the lowest host you need
via `min_host_version`; a `1.3` guest sets `"min_host_version": "1.3.0"` so an
older host refuses it cleanly rather than failing to link.

## Reference

- WIT contract: `native/mydia_plugin_sdk/wit/plugin.wit`
- SDK crate: `native/mydia_plugin_sdk`
- Starter: `native/mydia_plugin_sdk/examples/minimal`
- Reference plugin: `plugins/webhook_notifier`
- Sideload helper: `native/mydia_plugin_sdk/sideload.sh`
