# Plugin Development

This section is for developers building Mydia plugins. If you just want to use a
plugin someone else wrote, install and configure it from the admin UI; you do
not need any of this.

Mydia plugins are small, sandboxed programs that react to what happens in your
library. When a movie is added, a download completes, a file is imported, or
someone finishes watching something, Mydia hands the event to your plugin and
lets it do something useful: post a notification, call an external API, enrich
the event with library data. Plugins can also run on a fixed schedule, keep a
little durable state, link a per-user third-party account, and sync watched
state both ways. The bundled Simkl plugin does all of this.

A plugin is a WebAssembly **component** written in Rust against the published
`mydia-plugin-sdk` crate. You write one typed handler function; the SDK turns it
into a component the host can load. The plugin runs in a sandbox with no ambient
network, filesystem, or OS access. The only way out is through a small set of
capability-gated host functions you declare up front.

If you just want to get something working, follow the quickstart below, then
jump into the [Cookbook](cookbook.md) for task-by-task recipes. For the full
contract, capability model, and ABI details, see the [Reference](authoring.md).

## Quickstart

### 1. Create the crate

A plugin is a `cdylib` crate that depends on the SDK.

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

### 2. Write the handler

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
generated bindings. The handler takes a typed [`Event`](cookbook.md#act-on-only-the-events-you-care-about)
and returns a short JSON result string on success, or an error string the host
records as a plugin error.

### 3. Build the component

```bash
cargo build --release --target wasm32-wasip2
```

The component lands at `target/wasm32-wasip2/release/my_plugin.wasm`.

!!! tip "Toolchain"
    You need the `wasm32-wasip2` target: `rustup target add wasm32-wasip2`. If
    you build inside the Mydia repo, the devenv shell (`./dev shell`) provides
    it. The SDK's `wit-bindgen` dependency generates the component bindings, so
    no system binding generator is required.

!!! warning "Always set `panic = \"abort\"`"
    The sandbox denies stdio. A guest that panics and tries to print to stderr
    on its way down trips a host-side limitation and times out instead of
    failing cleanly. `panic = "abort"` traps immediately with no stderr write.

### 4. Ship a manifest

A plugin needs a JSON manifest declaring its identity, the events it subscribes
to, and the capabilities it wants. The smallest useful one:

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

See [Manifest & Settings](manifest.md) for every field, and the
[Cookbook](cookbook.md) for how to actually do things once an event arrives.
