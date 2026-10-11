#!/usr/bin/env bash
# Builds the Cardigann guest in Docker so no host .NET is needed.
#   build.sh check   compile as a plain net10.0 library
#   build.sh test    run the xunit tests on plain .NET
#   build.sh wasm    produce out/cardigann.wasm (wasip2 component with wasi:http
#                    and wasi:sockets composed out) and out/cardigann-raw.wasm
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/scripts/fetch-prowlarr.sh"

image="mcr.microsoft.com/dotnet/sdk:10.0"
cache="${NUGET_CACHE:-$HOME/.cache/mydia-cardigann-nuget}"
mkdir -p "$cache" "$cache-wasi-sdk"
# Run as the invoking user so bin/, obj/ and out/ are not root-owned.
run() {
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e DOTNET_CLI_HOME=/tmp -e NUGET_PACKAGES=/nuget \
    -v "$here:/src" -w /src \
    -v "$cache:/nuget" \
    -v "$cache-wasi-sdk:/tmp/.wasi-sdk" \
    "$image" bash -c "$1"
}

case "${1:-}" in
  check) run "dotnet build CardigannGuest.csproj -c Release -p:WasmBuild=false" ;;
  test)  run "dotnet test tests/CardigannGuest.Tests -c Release" ;;
  wasm)
    # componentize-dotnet's SDK publishes as part of `dotnet build`; a separate
    # `dotnet publish` hits a circular Publish target.
    run "dotnet build CardigannGuest.csproj -c Release -p:WasmBuild=true \
         && mkdir -p out && cp bin/Release/net10.0/wasi-wasm/native/CardigannGuest.wasm out/cardigann-raw.wasm"
    # The raw component imports wasi:http and wasi:sockets (the .NET runtime
    # links them, the engine never calls them). Wasmex only links wasi:http with
    # allow_http: true, which also grants ambient network and DNS. Compose in
    # trapping stand-ins so the final component imports neither. See SPIKE.md,
    # "Sandbox lock".
    "$here/scripts/rust-tools.sh" '
      mkdir -p deny/gen
      wit-bindgen rust --stubs --generate-all --world deny --out-dir deny/gen deny/wit
      mv deny/gen/deny.rs deny/gen/stubs.rs
      cargo build --release --target wasm32-wasip2 --manifest-path deny/Cargo.toml
      wac plug --plug deny/target/wasm32-wasip2/release/cardigann_deny.wasm out/cardigann-raw.wasm -o out/cardigann.wasm
      if wasm-tools component wit out/cardigann.wasm | grep -E "import wasi:(http|sockets)"; then
        echo "build.sh: composed component still imports wasi:http or wasi:sockets" >&2
        exit 1
      fi'
    ;;
  *) echo "usage: build.sh check|test|wasm" >&2; exit 2 ;;
esac
