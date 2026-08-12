# Connect to a Service Endpoint

One recipe: talk to a server the operator configured (Jellyfin, Emby, Plex, a
self-hosted API) without hard-coding its hostname in `net:http`. It assumes the
[tutorial](../tutorial/write-your-first-plugin.md)'s crate layout.

**Goal:** declare how the operator supplies a server URL and token, list the
resulting instance connections, and call the server with relative paths. For the
manifest field reference, see [Manifest & Settings](../reference/manifest.md#service-endpoint-descriptor).

## Declare the descriptor

Add a `service_endpoint` connection to your manifest and grant the capabilities
the flow needs:

```json
"connection": {
  "type": "service_endpoint",
  "scope": "instance",
  "probe_path": "/System/Info",
  "fields": [
    { "key": "url", "label": "Server URL" },
    { "key": "token", "label": "API token", "secret": true }
  ],
  "auth": { "kind": "header", "key": "X-Emby-Token" }
},
"capabilities": {
  "events:subscribe": ["media_item.added"],
  "users:connections": [],
  "surfaces:write": ["connections"]
}
```

The operator adds one or more labeled connections under Configuration > Plugins.
Each row stores `base_urls` (ordered candidates), the secret, and the resolved
base the host probed. You never see the token.

For discovery flows where the address is not known up front, set
`"onboarding": "guest"` instead of `fields` and implement `on-connect` (below).

## Read instance connections

Use `connections-list` to enumerate what the operator configured. Filter on
`scope == instance` when you only care about service endpoints (as opposed to
per-user OAuth links):

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::ConnectionScope;

for c in host::connections_list().unwrap_or_default() {
    if c.scope == ConnectionScope::Instance {
        let _label = c.label;
        let _id = c.id;
    }
}
```

Each record carries identity and status only. Authenticated calls go through
`connection-request`, which attaches the stored secret host-side.

## Make relative requests

An instance connection accepts a **path**, not an absolute URL. The host
resolves the operator-configured base, probes candidates if needed, attaches
auth from the manifest descriptor, and sends the request:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::OutboundRequest;

let resp = host::connection_request(
    &conn.id,
    &OutboundRequest {
        url: "/Library/Refresh".into(),
        method: "POST".into(),
        headers: vec![],
        body: None,
    },
)?;
```

This path needs `users:connections` only. You do not need a `net:http` grant
for the server's hostname, because the guest never chooses the destination.
User-scoped OAuth connections still require absolute URLs and a matching
`net:http` grant.

If resolution fails (every candidate unreachable), the host clears the cached
base so the next call re-probes without operator action.

## Write an on-connect flow

When `"onboarding": "guest"`, the operator clicks Connect and the host invokes
your `on-connect` export once per turn. Export it with the SDK attribute:

```rust
#[mydia_plugin_sdk::plugin(on_connect = on_connect)]
fn on_event(_evt: Event) -> Result<String, String> { Ok("{}".into()) }
```

Each turn receives a `ConnectRequest` with:

| Field | Meaning |
|-------|---------|
| `step` | `"start"`, `"poll"`, or `"submit"`. |
| `state_json` | Opaque state you returned on the previous turn (`"{}"` at start). |
| `input_json` | Operator answers on `"submit"` (`"{}"` otherwise). |
| `config_json` | Operator plugin settings (`"{}"` when empty). |

Return one of three responses:

- **`Pending`** - show a code or message; the host re-invokes with `"poll"` after
  `interval_ms`.
- **`Prompt`** - show a form (`fields`) or picker (`choices`); the host
  re-invokes with `"submit"` and the operator's answers in `input_json`.
- **`Done`** - flow finished; the host drops the session.

When you know the endpoint, call `connection-upsert` (requires
`surfaces:write` scoped to `"connections"`) and return `Done`:

```rust
use mydia_plugin_sdk::types::{
    ConnectDone, ConnectPending, ConnectRequest, ConnectResponse, ConnectionDraft,
};

fn on_connect(req: ConnectRequest) -> Result<ConnectResponse, String> {
    match req.step.as_str() {
        "start" => Ok(ConnectResponse::Pending(ConnectPending {
            message: "Enter the code at the provider".into(),
            code: Some("TEST-CODE".into()),
            verification_url: Some("https://provider.example/link".into()),
            interval_ms: 2_000,
            state_json: "{}".into(),
        })),
        "poll" => {
            host::connection_upsert(&ConnectionDraft {
                label: "Discovered".into(),
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
        other => Err(format!("unexpected step {other}")),
    }
}
```

Sessions expire after ten minutes. Carry multi-step state in `state_json`; do
not assume the guest stays open between turns.

## Next steps

- [Host API reference](../reference/host-api.md) - `connection-upsert`, `on-connect`, and the capability table
- [The plugin model](../explanation/plugin-model.md#operator-configured-endpoints-and-the-trust-boundary) - why relative requests skip the allowlist
- [Build a two-way sync](two-way-sync.md) - per-user OAuth connections and `connection-request` with absolute URLs
