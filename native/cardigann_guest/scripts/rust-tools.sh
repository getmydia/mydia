#!/usr/bin/env bash
# Runs a command in a pinned Rust container that has the wasm32-wasip2 target,
# wit-bindgen-cli and wac-cli. Caches live under ~/.cache/mydia-cardigann-cargo
# so only the first run compiles the tools.
#   rust-tools.sh '<shell command>'   (cwd is native/cardigann_guest)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
RUST_IMAGE="${RUST_IMAGE:-rust:1.96}"
WIT_BINDGEN_VERSION=0.62.0
WAC_VERSION=0.12.0
WASM_TOOLS_VERSION=1.258.0
cache="${CARGO_CACHE:-$HOME/.cache/mydia-cardigann-cargo}"
mkdir -p "$cache"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e CARGO_HOME=/cargo -e RUSTUP_HOME=/cargo/rustup \
  -e PATH=/cargo/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin \
  -v "$cache:/cargo" \
  -v "$here:/src" -w /src \
  "$RUST_IMAGE" bash -c "
    set -euo pipefail
    [ -d /cargo/rustup ] || cp -r /usr/local/rustup /cargo/rustup
    rustup target list --installed | grep -q wasm32-wasip2 || rustup target add wasm32-wasip2
    [ -x /cargo/bin/wit-bindgen ] || cargo install --locked --root /cargo wit-bindgen-cli --version $WIT_BINDGEN_VERSION
    [ -x /cargo/bin/wac ] || cargo install --locked --root /cargo wac-cli --version $WAC_VERSION
    [ -x /cargo/bin/wasm-tools ] || cargo install --locked --root /cargo wasm-tools --version $WASM_TOOLS_VERSION
    $1"
