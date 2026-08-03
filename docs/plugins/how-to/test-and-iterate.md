# Test and Iterate

Two recipes for the part of plugin development that isn't writing the handler:
proving it works without a running host, and getting new bytes into a running
Mydia without restarting it.

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

**Goal:** rebuild a plugin and load the new bytes into a running Mydia without
a restart.

Mydia reads an **override directory** (`PLUGINS_OVERRIDE_DIR`) as the
highest-precedence source of plugin bytes. Drop a `<slug>.wasm` there and it
shadows the installed copy; re-activating the plugin picks it up live, no host
restart. The loop:

```bash
# 1. Build the component. See the tutorial's "Build the component" step for
#    the wasm32-wasip2 toolchain requirement (the nix/devenv shell provides
#    it; a plain Docker setup does not).
cargo build --release --target wasm32-wasip2

# 2. Copy it into the override dir, named by your manifest slug.
#    (hyphen or underscore both resolve)
cp target/wasm32-wasip2/release/my_plugin.wasm "$PLUGINS_OVERRIDE_DIR/my-plugin.wasm"

# 3. Re-activate the plugin (toggle it in the admin UI, or call
#    Mydia.Plugins.reload/0 from an IEx session), then trigger an event.
```

So the cycle is `edit -> build -> copy -> re-activate -> test`. The plugin must
already be installed (its manifest seeded) so the host knows its capabilities;
the copy only refreshes the Wasm bytes.

!!! tip "Shortcut for repo contributors"
    If you have the Mydia repo checked out, `native/mydia_plugin_sdk/sideload.sh`
    wraps steps 1 and 2 into one command:

    ```bash
    export PLUGINS_OVERRIDE_DIR=/path/mydia/reads
    native/mydia_plugin_sdk/sideload.sh path/to/my_plugin --name my-plugin
    ```

    External plugin authors who pull the SDK as a dependency will not have this
    script, so the manual build-and-copy above is the canonical path.
