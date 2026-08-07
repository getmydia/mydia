#!/usr/bin/env bash
# Build the Flutter web player, including the wasm build of mydia_p2p_core.
#
# cargokit (player/rust_builder) has no web platform, so the Rust half is
# built here by flutter_rust_bridge's own web builder rather than by the
# Flutter build itself.
set -euo pipefail

cd "$(dirname "$0")/.."

# flutter_rust_bridge_codegen must match the flutter_rust_bridge version the
# crate pins. A mismatch does not fail, it regenerates every binding at the
# wrong version, so the check is up front and by absolute path: a stale copy in
# ~/.cargo/bin wins on PATH inside the devenv shell.
FRB="${CARGO_INSTALL_ROOT:?run this inside the devenv shell}/bin/flutter_rust_bridge_codegen"
"$FRB" --version | grep -qF 2.12.0 || {
  echo "ERROR: flutter_rust_bridge_codegen must be 2.12.0, got $("$FRB" --version)" >&2
  exit 1
}

echo "==> Building mydia_p2p_core for wasm"

# `$FRB build-web` is only a wrapper: it shells out to `dart run
# flutter_rust_bridge build-web`, and plain `dart` cannot resolve this
# package's `sdk: flutter` dependencies, so it dies in version solving before
# reaching the Rust build. The same Dart entrypoint is invoked here through
# `flutter pub run`, which can.
#
# RUSTC_BOOTSTRAP is the awkward part. build-web hardcodes
# `-Z build-std=std,panic_abort` and exports RUSTUP_TOOLCHAIN=nightly for
# wasm-pack, but cargo inside devenv is a plain pinned 1.96.0 binary rather
# than a rustup shim, so RUSTUP_TOOLCHAIN is ignored and `-Z` is rejected on
# the stable channel. The alternative is a second Rust toolchain, and the Rust
# version is meant to live in rust-toolchain.toml and nowhere else. `rust-src`,
# which build-std needs, already comes from devenv.nix.
export RUSTC_BOOTSTRAP=1

# The first line is flutter_rust_bridge's own default; restating it keeps its
# "your override drops the default" warning quiet. The link args are the
# addition, and none of them is optional.
#
# flutter_rust_bridge runs every non-async, non-`#[frb(sync)]` Rust function on
# a pool of web workers that share this module's linear memory, and it hands
# each worker that memory over `postMessage`. A `WebAssembly.Memory` is only
# serializable when it is shared, so a module whose memory is private fails
# there with a DataCloneError. `init_app` is one of those functions, so the
# failure would land on `RustLib.init()` itself, before the app draws anything.
#
# `+atomics` alone used to imply a shared memory. On rustc 1.96 it does not:
# without --shared-memory the module comes out as `(memory 27)` with no
# `shared` flag, and wasm-bindgen then never runs its threading pass, so the
# breakage is silent until the browser refuses the postMessage.
#
# --export=__wasm_init_tls is the other half. lld synthesises that function for
# a shared-memory module but does not export it, and wasm-bindgen's threading
# pass fails with "failed to find `__wasm_init_tls`" when it cannot see it.
#
# The consequence is that the page must be cross-origin isolated, since a
# shared memory is a SharedArrayBuffer. See web/_headers.
WASM_RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--shared-memory"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--import-memory"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--max-memory=1073741824"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--export=__wasm_init_tls"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--export=__tls_base"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--export=__tls_size"
WASM_RUSTFLAGS="$WASM_RUSTFLAGS -C link-arg=--export=__tls_align"

# --output must be absolute: wasm-pack resolves its output directory relative
# to the crate, so the default `./web` would land in rust/mydia_player_p2p/web
# instead of the Flutter package's own web/ directory.
flutter pub run flutter_rust_bridge build-web \
  --dart-root . \
  --rust-root rust/mydia_player_p2p \
  --output "$PWD/web" \
  --wasm-pack-rustflags "$WASM_RUSTFLAGS" \
  --release

echo "==> Building Flutter web bundle"
# MYDIA_WEB_P2P is what tells main.dart the module above is there. Without it
# the web build skips RustLib.init() entirely, which is what the same-origin
# bundle at /player wants: flutter_rust_bridge's loader awaits a <script> load
# event with no error path, so a missing module hangs startup rather than
# failing it.
flutter build web --release --base-href / --dart-define=MYDIA_WEB_P2P=true

echo "==> Done: build/web"
