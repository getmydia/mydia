# Write Your First Plugin

By the end of this tutorial you'll have a plugin that logs the title of every
item added to your library, built as a WebAssembly component and running inside
your own Mydia instance. It takes about 15 minutes, most of it the first
compile.

## Prerequisites

- A Mydia checkout with the [development environment](../../contributing/setup.md)
  working, and the server running in the background:

    ```bash
    ./dev up -d
    ```

- [Rust](https://rustup.rs/) with `rustup`. Step 1 pins the compiler version
  and the `wasm32-wasip2` target for you.

## Step 1: Create the crate

Create a library crate anywhere outside the Mydia checkout:

```bash
cargo new --lib my-plugin
cd my-plugin
```

Replace `Cargo.toml` with this:

```toml
[package]
name = "my-plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mydia-plugin-sdk = { git = "https://github.com/getmydia/mydia", tag = "v0.16.0-beta.2" }
serde_json = "1"

[profile.release]
opt-level = "z"
lto = true
strip = true
panic = "abort"
```

`panic = "abort"` makes a crashing handler trap cleanly instead of timing out.

Add a `rust-toolchain.toml` next to it. The compiler version has to match the
one the Mydia host runs plugins with, and this file makes `cargo` install it
and the WebAssembly target on first use:

```toml
[toolchain]
channel = "1.96.0"
targets = ["wasm32-wasip2"]
```

## Step 2: Write the handler

Replace `src/lib.rs` with this:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::Event;
use serde_json::Value;

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    let root: Value = serde_json::from_str(&evt.metadata_json)
        .map_err(|e| format!("bad metadata_json: {e}"))?;
    let title = root["metadata"]["title"].as_str().unwrap_or("an untitled item");

    host::log("info", &format!("Added to the library: {title}"));
    Ok("{}".to_string())
}
```

The `#[mydia_plugin_sdk::plugin]` macro turns this plain function into the
component's event handler. The event's detail, here the title, arrives as JSON
in `metadata_json`. [`host::log`](../reference/host-functions.md#log) writes a
line to the plugin's activity log and needs no capability.

## Step 3: Write the manifest

Save this as `manifest.json` in the crate directory:

```json
{
  "slug": "my-plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "capabilities": {
    "events:subscribe": ["media_item.added"]
  }
}
```

It names the plugin and asks for one capability: subscribing to the
[`media_item.added`](../reference/events.md#media_itemadded) event. The full
field list is in the [manifest reference](../reference/manifest.md).

## Step 4: Build the component

```bash
cargo build --release --target wasm32-wasip2
```

The first build downloads the toolchain and the SDK, then compiles. It ends with
a `Finished` line, and the component is at
`target/wasm32-wasip2/release/my_plugin.wasm`. Cargo turns the hyphen in the
crate name into an underscore in the filename.

## Step 5: Install it

Run this from your Mydia checkout, with absolute paths to the two files. Replace
`/path/to/my-plugin` with the directory from step 1:

```bash
./dev mix mydia.plugin install \
  /path/to/my-plugin/target/wasm32-wasip2/release/my_plugin.wasm \
  /path/to/my-plugin/manifest.json \
  --approve
```

It ends with `Installed and activated my-plugin 0.1.0.` While the server is
running you'll also see a `Failed to bind iroh endpoint` error earlier in the
output. That's expected: the task starts a second copy of the app, and the
running server already holds the network port.

The task runs separately from the server, so restart the server to load the
plugin:

```bash
./dev restart
```

## Step 6: Run it

Sign in to Mydia as an admin and open **Admin > System > Plugins**. **My Plugin**
is listed and enabled. Then:

1. Click **Logs** on the My Plugin row.
2. Open the **Test** tab, pick `media_item.added` in the event list, and click
   **Run test**.
3. Switch to the **Activity** tab.

You'll see this line, badged `test`:

```text
Added to the library: Test Movie
```

The Test tab sent your plugin a synthetic `media_item.added` event, and your
handler logged its title. A real item added to your library produces the same
line with its own title.

## Step 7: Change it and run it again

In `src/lib.rs`, change the log line:

```rust
    host::log("info", &format!("Just added: {title}"));
```

Rebuild, install the new build and restart, using the commands from steps 4 and
5:

```bash
cargo build --release --target wasm32-wasip2 \
  --manifest-path /path/to/my-plugin/Cargo.toml
```

```bash
./dev mix mydia.plugin install \
  /path/to/my-plugin/target/wasm32-wasip2/release/my_plugin.wasm \
  /path/to/my-plugin/manifest.json \
  --approve
./dev restart
```

Run the test from **Logs > Test** again. The Activity tab now shows `Just added:
Test Movie`.

That is the whole development loop. To remove the plugin when you're done, click
the trash icon on its row in **Admin > System > Plugins**.

## Where to go next

- [Test and iterate](../how-to/test-and-iterate.md) shortens this loop and covers
  the Logs modal, unit tests and installing on a real server.
- The [how-to guides](../how-to/notifications.md) cover notifications, reading
  media data and two-way sync.
- The [events](../reference/events.md), [capabilities](../reference/capabilities.md)
  and [host functions](../reference/host-functions.md) references list what a
  plugin can listen to and call.
- [The plugin model](../explanation/plugin-model.md) explains why plugins are
  sandboxed and approved the way they are.
