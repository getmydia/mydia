# Bundled plugin guests

Guests are wasip2 **components** (WIT `mydia:plugin@1.6.0`, built on the
`mydia-plugin-sdk` crate and the `#[mydia_plugin_sdk::plugin]` macro), which the host runs
via `Wasmex.Components.*`. They migrated from `wasm32-unknown-unknown` core
modules.

## Design rule: the host owns shared nouns, the plugin owns behaviour

Before designing a plugin or extending the WIT contract, read
[What the host owns and what a plugin owns](../docs/plugins/explanation/plugin-model.md#what-the-host-owns-and-what-a-plugin-owns).
In short, anything the admin UI, a profile page, another feature or another
plugin must see is stored by the host and written through the contract. That
covers watch state, account links, sync runs, health, secrets and instances.
Protocol logic and the plugin's own working state stay in the guest. A plugin
never keeps the only copy of a host noun in KV, new nouns are generic rather
than service-named, and the host renders all UI from declarative steps.

## Bundled guests

| Guest | What it does |
|---|---|
| `simkl_sync` | Two-way watched-state and list sync with Simkl, per user. |
| `webhook_notifier` | Discord, ntfy and custom webhooks on library events. |
| `plex` | Plex media servers: sign-in, server discovery, library refresh, two-way watched sync, Plex Home profiles. Multi-instance. |

## Building the guests

Inside the devenv shell the Rust toolchain already has `wasm32-wasip2` and
`wasm-tools`. `./dev mix compile` runs the `:plugins` Mix compiler
(`lib/mix/tasks/compile/plugins.ex`), which builds every crate under `plugins/`
and writes `priv/plugins/<name>.wasm`, so the normal dev loop needs nothing
extra. If `cargo` or the `wasm32-wasip2` target is missing, the compiler skips
with a loud warning and leaves any existing artifact in place.

To build one guest by hand, from the repository root inside the devenv shell:

```bash
cargo build --release --target wasm32-wasip2 \
  --manifest-path plugins/<name>/Cargo.toml
cp plugins/<name>/target/wasm32-wasip2/release/<name>.wasm \
  priv/plugins/<name>.wasm   # gitignored; CI rebuilds it
```

Host and sandbox tests use checked-in component fixtures under
`test/support/fixtures/plugins/*/`, because WAT cannot express components.

The runtime limits, and what the sandbox does and does not enforce, are listed
in [Limits](../docs/plugins/reference/limits.md); the reasoning is in
[The plugin model](../docs/plugins/explanation/plugin-model.md). One guest-side
trap to know about: a guest that writes to denied stderr on a trap trips a
wasmtime-wasi sync `block_on` panic, so use `panic = "abort"` or
`process::abort()` to make guests trap cleanly.

## The guest WASI version is pinned to the Rust toolchain

A wasip2 component's imported WASI world version tracks the Rust toolchain
version. rustc 1.96 emits `wasi 0.2.6` and newer stable emits `0.2.9`. The
runtime host is wasmex 0.15.1 and wasmtime 47, which implements
`wasi:cli/command@0.2.12`, so both worlds link today.

A guest built with a too-new Rust fails `Wasmex.Components.Component.new`, and
`Mydia.Plugins.activate/1` translates that `:compile_failed` or
`:instantiate_failed` into a misleading `:host_version` error: "plugin X requires
a newer Mydia host (incompatible plugin contract)". The message points at the
host and manifest rather than at the real cause.

nix pins Rust via `rust-bin.stable.latest`, frozen by `flake.lock` at 1.96, while
CI's `dtolnay/rust-toolchain@stable` and the Dockerfiles'
`rustup --default-toolchain stable` fetched bleeding-edge stable at run time.
Guests that validated green locally under nix at 0.2.6 went red in CI at 0.2.9.

Keep the Rust version pinned and in sync across all four guest-building toolchain
sources: `nix/devShells/flake-module.nix` (the source of truth),
`.github/workflows/ci.yml` (three `dtolnay/rust-toolchain@<ver>` steps), and
`Dockerfile`, `Dockerfile.e2e` and `Dockerfile.dev` (`--default-toolchain <ver>`).
Bump them together when nix moves.

To diagnose, this shows the emitted WASI version:

```bash
nix develop .#rust -c bash -c 'cd plugins/<g> && cargo build --release --target wasm32-wasip2 && wasm-tools component wit target/wasm32-wasip2/release/<g>.wasm | grep wasi'
```

Raising the ceiling means bumping wasmex past 0.15.1.

## A new guest needs per-crate nix vendoring

Each guest under `plugins/<name>/` is its own cargo crate with its own
`Cargo.lock`. The Nix `package` derivation (`nix/packages/flake-module.nix`)
builds the guests offline inside a no-network sandbox during `mix compile`, so
every guest needs its deps vendored explicitly: an `importCargoLock` binding such
as `simklSyncCargoDeps`, plus a `.cargo/config.toml` written in `postConfigure`
pointing `source.crates-io` at the vendored dir. The list is hardcoded per crate,
not globbed.

simkl_sync (commit `8ef14ecd`) was added without this, so only webhook_notifier
was vendored, and `Build / Packages` (the `CI / Nix` workflow's
`nix flake check` building `checks.x86_64-linux.package`) failed compiling the
simkl guest. The failure is silent: the plugins Mix compiler captures cargo
stderr, and the sandbox dies after `[plugins] compiling <name>` with no error text
in `nix log`. It builds fine standalone, because the host has network and a cargo
cache, so it only reproduces via `nix build .#checks.x86_64-linux.package` or in
CI. Docker builders are unaffected.

When adding a guest, mirror the webhook_notifier vendoring block in
`flake-module.nix`, both the `importCargoLock` and the `.cargo/config.toml` write.
Verify with `nix build .#checks.x86_64-linux.package -L` before pushing; a green
local `./dev` will not catch it.

## Plugins that are not bundled

Everything under `plugins/` ships in the Mydia image. Plugins that operators
install from the official index instead live in `plugins-extra/`; see
`plugins-extra/README.md` for their layout and how they are published.
