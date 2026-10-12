#!/usr/bin/env bash
# Runs a command in a pinned Rust container that has the wasm32-wasip2 target,
# wit-bindgen-cli, wac-cli and wasm-tools. Caches live under
# ~/.cache/mydia-cardigann-cargo; each tool installs into a version-specific
# root, so bumping a version below reinstalls it.
#   rust-tools.sh '<shell command>'   (cwd is native/cardigann_guest)
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
RUST_IMAGE="${RUST_IMAGE:-rust:1.96@sha256:1f0dbad1df66647807e6952d1db85d0b2bda7606cb2139d82517e4f009967376}"
WIT_BINDGEN_VERSION=0.62.0
WAC_VERSION=0.12.0
WASM_TOOLS_VERSION=1.258.0
cache="${CARGO_CACHE:-$HOME/.cache/mydia-cardigann-cargo}"
mkdir -p "$cache"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e CARGO_HOME=/cargo -e RUSTUP_HOME=/cargo/rustup \
  -e "PATH=/cargo/tools/wit-bindgen-cli-$WIT_BINDGEN_VERSION/bin:/cargo/tools/wac-cli-$WAC_VERSION/bin:/cargo/tools/wasm-tools-$WASM_TOOLS_VERSION/bin:/cargo/bin:/usr/local/cargo/bin:/usr/local/bin:/usr/bin:/bin" \
  -v "$cache:/cargo" \
  -v "$here:/src" -w /src \
  "$RUST_IMAGE" bash -c "
    set -euo pipefail
    [ -d /cargo/rustup ] || cp -r /usr/local/rustup /cargo/rustup
    rustup target list --installed | grep -q wasm32-wasip2 || rustup target add wasm32-wasip2
    tool() { # crate version binary
      [ -x /cargo/tools/\$1-\$2/bin/\$3 ] || cargo install --locked --root /cargo/tools/\$1-\$2 \$1 --version \$2
    }
    tool wit-bindgen-cli $WIT_BINDGEN_VERSION wit-bindgen
    tool wac-cli $WAC_VERSION wac
    tool wasm-tools $WASM_TOOLS_VERSION wasm-tools
    $1"
