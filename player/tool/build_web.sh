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
#
# The version is read from the crate rather than restated here, matching
# nix/devShells/flake-module.nix. A literal in this file goes stale the moment
# the pin moves, and the failure it then permits is the one it exists to catch.
FRB="${CARGO_INSTALL_ROOT:?run this inside the devenv shell}/bin/flutter_rust_bridge_codegen"
FRB_VERSION="$(sed -n 's/^flutter_rust_bridge = "=\(.*\)"$/\1/p' \
  rust/mydia_player_p2p/Cargo.toml)"
if [ -z "$FRB_VERSION" ]; then
  echo "ERROR: could not read the flutter_rust_bridge pin from player/rust/mydia_player_p2p/Cargo.toml" >&2
  exit 1
fi
"$FRB" --version | grep -qF "$FRB_VERSION" || {
  echo "ERROR: flutter_rust_bridge_codegen must be $FRB_VERSION, got $("$FRB" --version)" >&2
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
# `-Z build-std=std,panic_abort`, which stable cargo rejects. The alternative
# is a second Rust toolchain, and the Rust version is meant to live in
# rust-toolchain.toml and nowhere else. `rust-src`, which build-std needs,
# already comes from devenv.nix.
export RUSTC_BOOTSTRAP=1

# build-web also exports RUSTUP_TOOLCHAIN=nightly into wasm-pack's environment
# unless it is told otherwise, so the toolchain is named here, read from the
# single source of truth rather than restated.
#
# It is not enough that devenv's cargo is a plain binary that ignores
# RUSTUP_TOOLCHAIN. That is a property of one machine: ~/.cargo/bin is on PATH
# inside the devenv shell (it is how wasm-pack itself resolves), and anywhere a
# rustup-shimmed cargo wins that PATH, the wasm shipped to browsers would be
# built by whatever nightly happens to be installed. RUSTC_BOOTSTRAP above
# would then make that divergence silent instead of an error, and the CI
# toolchain guard cannot see it because rust-toolchain.toml stays untouched.
RUST_CHANNEL="$(sed -n 's/^channel = "\(.*\)"$/\1/p' ../rust-toolchain.toml)"
[ -n "$RUST_CHANNEL" ] || {
  echo "ERROR: could not read [toolchain] channel from rust-toolchain.toml" >&2
  exit 1
}

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
  --wasm-pack-rustup-toolchain "$RUST_CHANNEL" \
  --release

echo "==> Checking the wasm module"

# Everything above fails loudly except the one thing that matters most. Drop
# --shared-memory and the module still builds, wasm-bindgen simply skips its
# threading pass, wasm-pack reports success, and nothing goes wrong until a
# browser refuses to postMessage the memory to a worker. So the shape of the
# artifact is asserted rather than inferred from the flags that produced it.
WASM_GLUE="web/pkg/mydia_player_p2p.js"
WASM_MODULE="web/pkg/mydia_player_p2p_bg.wasm"

for f in "$WASM_GLUE" "$WASM_MODULE"; do
  [ -f "$f" ] || {
    echo "ERROR: build-web reported success but $f is missing." >&2
    exit 1
  }
done

grep -qE 'new WebAssembly\.Memory\(\{[^}]*shared:[[:space:]]*true' "$WASM_GLUE" || {
  echo "ERROR: $WASM_GLUE does not construct a shared WebAssembly.Memory." >&2
  echo "       The module was built without shared memory, so flutter_rust_bridge" >&2
  echo "       cannot hand it to a web worker and RustLib.init() dies in the" >&2
  echo "       browser with a DataCloneError. Check the --shared-memory and" >&2
  echo "       --export=__wasm_init_tls link args above." >&2
  exit 1
}

echo "==> Building Flutter web bundle"
# MYDIA_WEB_P2P is what tells main.dart the module above is there. Without it
# the web build skips RustLib.init() entirely, which is what the same-origin
# bundle at /player wants: flutter_rust_bridge's loader awaits a <script> load
# event with no error path, so a missing module hangs startup rather than
# failing it.
#
# --no-web-resources-cdn keeps CanvasKit local. The default resolves it to
# https://www.gstatic.com/flutter-canvaskit/<rev> and flutter.js injects that
# script with no `crossorigin` attribute, making it a no-cors cross-origin
# load. Under the COEP require-corp this page ships (web/_headers) that is
# blocked unless gstatic volunteers a Cross-Origin-Resource-Policy header, and
# there is no CORS fallback in that path. The local copies are in the bundle
# already, and a public page is better off not calling out to a third party.
#
# --pwa-strategy=none because a scope holds exactly one service worker
# registration, and web/sw.js has to take the app's own scope: a worker
# controls only clients whose URL is inside its scope, and the app page is at
# the base href. Left on, Flutter's worker and the media worker would replace
# each other's registration on every load and playback cycle. This is the
# build that runs the p2p proxy, so it is the one that must not do that.
# Flutter's own build output already calls its service worker deprecated.
flutter build web --release --base-href / \
  --no-web-resources-cdn \
  --pwa-strategy=none \
  --dart-define=MYDIA_WEB_P2P=true

# The module is only useful if flutter copied it across. This is the same
# failure as a partial upload, caught here rather than in a browser.
[ -f build/web/pkg/mydia_player_p2p.js ] || {
  echo "ERROR: web/pkg did not make it into build/web." >&2
  exit 1
}

# _headers is the file that makes the whole bundle work: without the COOP/COEP
# lines it carries, the page never becomes cross-origin isolated, there is no
# SharedArrayBuffer, and RustLib.init() throws in every browser that loads it.
# A host that silently drops dotfiles, or a future change to what web/
# contains, would ship a page that looks deployed and is not.
[ -f build/web/_headers ] || {
  echo "ERROR: _headers did not make it into build/web. The page will not be" >&2
  echo "       cross-origin isolated and RustLib.init() will fail in every browser." >&2
  exit 1
}

echo "==> Done: build/web"
