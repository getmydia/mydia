#!/usr/bin/env bash
set -euo pipefail

# Mydia plugin sideload helper — the SDK dev loop (R13).
#
# Builds a plugin crate to a wasm32-wasip2 component and drops it into the
# operator override directory, so a running Mydia host picks up the new bytes on
# the next activation with no restart. That holds for a plugin that is already
# installed, when PLUGINS_OVERRIDE_DIR was set before the server booted (it is
# read at boot only). The loop is:
#
#   edit  ->  sideload.sh  ->  Disable then Enable in Admin > System > Plugins  ->  test
#
# The override dir is the highest-precedence artifact layer in
# Mydia.Plugins.resolve_artifact/2: a `<name>.wasm` placed there shadows the DB
# blob and the image-bundled artifact. The plugin must already be installed (its
# manifest seeded) so the host knows its capabilities; this helper only refreshes
# the wasm bytes.
#
# Usage:
#   sideload.sh [CRATE_DIR] [--name NAME] [--dir OVERRIDE_DIR]
#
#   CRATE_DIR        plugin crate to build (default: current directory)
#   --name NAME      output filename stem (default: the built .wasm's name).
#                    Use the plugin slug (hyphenated or underscored both resolve).
#   --dir DIR        override dir (default: $PLUGINS_OVERRIDE_DIR)
#
# Requires the wasm32-wasip2 target (`rustup target add wasm32-wasip2`, or run
# inside the devenv shell, which bakes the target in).

crate_dir="."
name=""
override_dir="${PLUGINS_OVERRIDE_DIR:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    --dir)
      override_dir="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,30p' "$0"
      exit 0
      ;;
    *)
      crate_dir="$1"
      shift
      ;;
  esac
done

if [ -z "$override_dir" ]; then
  echo "error: no override dir. Set PLUGINS_OVERRIDE_DIR or pass --dir DIR." >&2
  exit 1
fi

crate_dir="$(cd "$crate_dir" && pwd)"
target="wasm32-wasip2"

echo "==> building $(basename "$crate_dir") for $target"
cargo build --release --target "$target" --manifest-path "$crate_dir/Cargo.toml"

# The component lands in the workspace/crate target dir under the target triple.
target_dir="$(
  cargo metadata --no-deps --format-version 1 --manifest-path "$crate_dir/Cargo.toml" \
    | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p'
)"
built="$(find "$target_dir/$target/release" -maxdepth 1 -name '*.wasm' -print -quit)"

if [ -z "$built" ] || [ ! -f "$built" ]; then
  echo "error: no .wasm produced under $target_dir/$target/release" >&2
  exit 1
fi

stem="${name:-$(basename "$built" .wasm)}"
mkdir -p "$override_dir"
dest="$override_dir/$stem.wasm"
cp "$built" "$dest"

echo "==> sideloaded $dest ($(wc -c <"$dest") bytes)"
echo "    Disable then Enable the plugin in Admin > System > Plugins to load it."
