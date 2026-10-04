# Test and Iterate

Recipes for the part of plugin development that isn't writing the handler:
getting a build into Mydia, firing events at it, reading what it did, and
testing without a host at all. The [tutorial](../tutorial/write-your-first-plugin.md)
walks the first loop end to end.

## Install your build

**Goal:** put a freshly built component and its manifest into a development
instance, approved and enabled.

1. Build the component:

    ```bash
    cargo build --release --target wasm32-wasip2
    ```

    The file is `target/wasm32-wasip2/release/<crate_name>.wasm`, with hyphens in
    the crate name turned into underscores.

2. From your Mydia checkout, install it with absolute paths:

    ```bash
    ./dev mix mydia.plugin install /abs/path/my_plugin.wasm /abs/path/manifest.json --approve
    ```

    `--approve` grants the capabilities the manifest declares. Without it the
    plugin installs inactive, and you approve it in **Admin > System > Plugins**.
    Installing the same slug again replaces the bytes and manifest and clears the
    grant, so pass `--approve` each time or approve it again in the UI.

3. Restart the server so it loads the install:

    ```bash
    ./dev restart
    ```

The task starts its own copy of the app, so while the server is running it logs
a harmless `Failed to bind iroh endpoint` error. The install itself still
succeeds.

`install` refuses a bundled plugin's slug. To replace those bytes, see
[Replace a bundled plugin's bytes](#replace-a-bundled-plugins-bytes).

## Fire a test event

**Goal:** run your handler without waiting for real activity.

1. Open **Admin > System > Plugins** and click **Logs** on your plugin's row.
2. Open the **Test** tab.
3. Pick an event from the list and click **Run test**.

The list holds the events the plugin subscribes to, so a plugin with no
`events:subscribe` entry has nothing to test, and a disabled plugin shows
"Enable this plugin to send it a test event." The handler gets a synthetic
event with invented detail (for `media_item.added`, the title is `Test Movie`),
and its log lines carry a `test` badge.

For a plugin with several instances, such as a setup-wizard source, the test
runs against the first enabled instance.

## Read logs and network requests

**Goal:** see what the handler logged and what requests it made.

Click **Logs** on the plugin's row. The modal has three tabs:

| Tab | Shows |
|-----|-------|
| **Activity** | The [`log`](../reference/host-functions.md#log) lines from your guest, plus host lines for each invocation and its result. Filter by minimum level or search the text. |
| **Network** | Every outbound request the plugin made: time, method, URL, status, size, duration and outcome. Requests are gated by the [`net:http`](../reference/capabilities.md#nethttp) allowlist. |
| **Test** | The event picker from the previous recipe. |

Lines arrive live while the modal is open.

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
        let evt = event("media_item.added", r#"{"metadata":{"title":"Example"}}"#);
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

This is how the bundled notifier stays fully unit-tested. Its `src/lib.rs` is
worth reading for the pattern at scale.

!!! note "Host logging in tests"
    The tutorial's handler calls `host::log`, which is also a host function. Put
    it behind the same kind of shim if you want to unit-test that handler.

## Swap bytes without reinstalling

**Goal:** rebuild and load new bytes without running `install` and restarting
every time.

Mydia reads an **override directory** as the highest-precedence source of plugin
bytes. A `<slug>.wasm` there shadows the installed copy, and the hyphenated or
underscored slug both work as the filename stem. The directory is read when the
server boots, so this needs one-time setup:

1. Install the plugin once, as in [Install your build](#install-your-build).
2. Set `PLUGINS_OVERRIDE_DIR` to a directory you own in the environment the
   server starts in, then restart the server.
3. Build and drop the bytes in with `sideload.sh`, which lives in the Mydia
   checkout:

    ```bash
    native/mydia_plugin_sdk/sideload.sh /path/to/my-plugin --name my-plugin
    ```

    It builds the crate and copies the component to
    `$PLUGINS_OVERRIDE_DIR/my-plugin.wasm`. The same two steps by hand are
    `cargo build --release --target wasm32-wasip2` and a `cp` of the built
    component to that path.

4. In **Admin > System > Plugins**, click **Disable**, then **Enable** on the
   plugin. Enabling re-resolves the artifact, so the new bytes load without a
   restart.
5. Run a test from **Logs > Test**.

The loop is edit, `sideload.sh`, Disable then Enable, test. The plugin must
already be installed so the host knows its capabilities; the override only
replaces the bytes. Changes to `manifest.json` still need a reinstall.

## Replace a bundled plugin's bytes

**Goal:** run your own build of a plugin that ships with Mydia, such as to try a
fix.

`install` refuses the slug of a bundled plugin. Use the override directory
instead: set `PLUGINS_OVERRIDE_DIR` before the server boots, place your build
there as `<slug>.wasm`, and restart. At boot the override shadows the bundled
bytes. Later builds go through the loop in
[Swap bytes without reinstalling](#swap-bytes-without-reinstalling). Remove the
file and restart to return to the bundled copy.

## Install on a real server

**Goal:** try an unpublished plugin on a running Mydia container.

Copy the component and its `manifest.json` somewhere the container can read,
such as the `/config` volume, then install them with `mydia-cli`:

```bash
docker exec mydia mydia-cli plugin install \
  /config/my_plugin.wasm /config/manifest.json
```

Paths are resolved inside the container. This runs against the live server, so
the plugin starts without a restart. It installs inactive unless you add
`--approve`; approve its declared capabilities in **Admin > System > Plugins**
otherwise. Running the command again with a new build replaces the bytes and
manifest and clears the grant. A bundled plugin cannot be replaced this way; use
the [override directory](#replace-a-bundled-plugins-bytes).
