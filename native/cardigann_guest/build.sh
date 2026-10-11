#!/usr/bin/env bash
# Builds the Cardigann guest in Docker so no host .NET is needed.
#   build.sh check   compile as a plain net10.0 library
#   build.sh test    run the xunit tests on plain .NET
#   build.sh wasm    produce out/cardigann.wasm (wasip2 component)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
"$here/scripts/fetch-prowlarr.sh"

image="mcr.microsoft.com/dotnet/sdk:10.0"
cache="${NUGET_CACHE:-$HOME/.cache/mydia-cardigann-nuget}"
mkdir -p "$cache"
run() {
  docker run --rm \
    -v "$here:/src" -w /src \
    -v "$cache:/root/.nuget/packages" \
    "$image" bash -c "$1"
}

case "${1:-}" in
  check) run "dotnet build CardigannGuest.csproj -c Release -p:WasmBuild=false" ;;
  test)  run "dotnet test tests/CardigannGuest.Tests -c Release" ;;
  wasm)
    run "dotnet publish CardigannGuest.csproj -c Release -p:WasmBuild=true -o out/publish \
         && cp out/publish/CardigannGuest.wasm out/cardigann.wasm"
    ;;
  *) echo "usage: build.sh check|test|wasm" >&2; exit 2 ;;
esac
