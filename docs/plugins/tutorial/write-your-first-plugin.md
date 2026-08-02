# Write Your First Plugin

By the end of this tutorial you'll have a plugin that logs a message every
time media is added to your library, built as a WebAssembly component and
running inside a real Mydia instance. It takes about 10 minutes.

## Prerequisites

- A local Mydia checkout with the [devenv shell](../../contributing/setup.md)
  working (`./dev shell` or `direnv allow`). Building the plugin needs the
  `wasm32-wasip2` Rust target, which only the devenv/nix path provides, not
  a plain Docker setup. If you're building outside the repo, add the target
  yourself: `rustup target add wasm32-wasip2`, matching the Rust toolchain
  Mydia pins (1.96.0, see [Development Setup](../../contributing/setup.md)) so
  the component's WASI ABI stays compatible with the host.
- A running Mydia instance you can activate plugins on (`./dev up`).

## Step 1: Create the Crate

A plugin is a `cdylib` crate that depends on the published `mydia-plugin-sdk`.
The starter at `native/mydia_plugin_sdk/examples/minimal` is exactly this
layout if you want to copy it instead of typing it out.

`Cargo.toml`:

```toml
[package]
name = "my_plugin"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
mydia-plugin-sdk = { git = "https://github.com/getmydia/mydia", branch = "master" }

[profile.release]
opt-level = "z"
lto = true
strip = true
panic = "abort"
```

!!! warning "Always set `panic = \"abort\"`"
    The sandbox denies stdio. A guest that panics and tries to print to stderr
    on its way down trips a host-side limitation and times out instead of
    failing cleanly. `panic = "abort"` traps immediately with no stderr write.

## Step 2: Write the Handler

`src/lib.rs`:

```rust
use mydia_plugin_sdk::types::Event;

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    Ok(format!("{{\"handled\":\"{}\"}}", evt.event))
}
```

That is a complete plugin. The `#[mydia_plugin_sdk::plugin]` macro adapts your
plain function onto the component's exported handler, so you never touch the
generated bindings. The handler takes a typed
[`Event`](../how-to/media-data.md#act-on-only-the-events-you-care-about) and
returns a short JSON result string on success, or an error string the host
records as a plugin error.

Because it's plain Rust, you can unit-test `on_event` directly with `cargo
test`, no Wasm build and no running host required. See
[Test without a host](../how-to/test-and-iterate.md#test-without-a-host) once
you're ready to go deeper on that.

## Step 3: Build the Component

```bash
cargo build --release --target wasm32-wasip2
```

The component lands at `target/wasm32-wasip2/release/my_plugin.wasm`. The
SDK's `wit-bindgen` dependency generates the component bindings, so no system
binding generator is required.

## Step 4: Ship a Manifest

A plugin needs a JSON manifest declaring its identity, the events it
subscribes to, and the capabilities it wants. The smallest useful one:

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

Save it as `priv/plugins/my-plugin.json` in your Mydia checkout. Mydia
discovers every manifest under `priv/plugins/` and seeds it as a disabled,
unapproved plugin the next time the app boots, or the next time you open the
admin Plugins page, whichever comes first: it's the same mechanism the
bundled webhook notifier and Simkl plugins use to register themselves, and
for local development it's the natural way to get a brand-new manifest known
to the host without a remote plugin index. See the full field reference in
[Manifest & Settings](../reference/manifest.md) when you need more than the
basics.

## Step 5: Load It and Watch It Run

Point Mydia's plugin override directory at your build and drop the component
in, named after the manifest slug (export this in the same environment the
Phoenix server runs in, before the next step, so the bytes are there the
first time Mydia looks for them):

```bash
export PLUGINS_OVERRIDE_DIR=/path/mydia/reads
cp target/wasm32-wasip2/release/my_plugin.wasm "$PLUGINS_OVERRIDE_DIR/my-plugin.wasm"
```

Open **Admin > Plugins**. Your plugin shows up in the installed list, pending
approval. Approve it: this grants the capabilities it declared and activates
it, resolving the Wasm bytes you just dropped in.

Now add or import a movie or show. Open the plugin's activity log: you'll see
the `on_event` result recorded for the `media_item.added` event you just
triggered.

That's the whole loop: build, install once, drop in new bytes, reload, test.
For the repeatable version of this, plus the `sideload.sh` shortcut for repo
contributors, see [Test and iterate](../how-to/test-and-iterate.md).

## What You Just Did

You built a Wasm component from a single typed handler function, declared what
it wants to react to in a manifest, and watched Mydia run it against a real
event with no host restart in between. Everything past this point is the same
shape: subscribe to more events, request more capabilities, reach for host
functions to read data or make calls.

- For task-by-task recipes (notifications, reading media data, two-way sync),
  see the [how-to guides](../how-to/notifications.md).
- For the full event, capability, and manifest contract, see the
  [reference](../reference/host-api.md).
- For why the platform is shaped this way, see
  [The plugin model](../explanation/plugin-model.md).
