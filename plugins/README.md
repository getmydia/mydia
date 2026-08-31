# Bundled plugin guests

Guests are wasip2 **components** (WIT `mydia:plugin@1.0.0`, built on the
`mydia-plugin-sdk` crate and the `#[mydia::plugin]` macro), which the host runs
via `Wasmex.Components.*`. They migrated from `wasm32-unknown-unknown` core
modules.

## Build them via nix, not the Docker dev container

The running Docker dev container only has `wasm32-unknown-unknown` installed. The
`Dockerfile.dev` `rustup target add wasm32-wasip2` change needs an image rebuild
to take effect. So `./dev mix compile` graceful-skips the `:plugins` compiler and
warns that the artifact is stale.

To produce a component artifact for tests, build via nix and let the placed
`priv/plugins/<name>.wasm` persist, since Docker skips and keeps it:

Run this from the repository root:

```bash
nix develop .#default -c cargo build --release --target wasm32-wasip2 \
  --manifest-path plugins/<name>/Cargo.toml
cp plugins/<name>/target/wasm32-wasip2/release/<name>.wasm \
  priv/plugins/<name>.wasm   # gitignored; CI rebuilds it
```

Both `nix develop .#default` and `.#rust` have `wasm32-wasip2` and `wasm-tools`.
Host and sandbox tests use checked-in component fixtures under
`test/support/fixtures/plugins/*/`, because WAT cannot express components.

Two accepted residuals under Wasmex 0.14 component stores, documented in the
`lib/mydia/plugins/host.ex` moduledoc: there is no fuel or CPU metering, and
`StoreLimits` caps memory only at instantiation rather than on runtime grow. A
guest that writes to denied stderr on a trap trips a wasmtime-wasi sync
`block_on` panic, so use `panic = "abort"` or `process::abort()` to make guests
trap cleanly.

## The guest WASI version is pinned to the Rust toolchain

A wasip2 component's imported WASI world version tracks the Rust toolchain
version. rustc 1.96 emits `wasi 0.2.6` and newer stable emits `0.2.9`. The
runtime host is wasmex 0.14 and wasmtime 39, which only validates components up
to wasi 0.2.6.

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

Raising the ceiling instead means bumping wasmex past 0.14.

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
