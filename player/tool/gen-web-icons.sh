#!/usr/bin/env bash
#
# Regenerate the Flutter player's web icon set from its SVG sources.
#
#   assets/icon.svg           -> web/favicon.svg, web/favicon.png,
#                                web/icons/Icon-192.png, web/icons/Icon-512.png
#   assets/icon-maskable.svg  -> web/icons/Icon-maskable-192.png,
#                                web/icons/Icon-maskable-512.png
#
# Usage:
#   tool/gen-web-icons.sh            Regenerate every output, refresh the hash record
#   tool/gen-web-icons.sh --check    Verify the record still matches the sources
#
# --check intentionally needs only coreutils, never rsvg-convert, so CI can run
# it with no nix and no rasterizer installed.

set -euo pipefail

# Resolve to player/ no matter where the caller invoked this from.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

RECORD="tool/icon-sources.sha256"
SOURCES=(assets/icon.svg assets/icon-maskable.svg)

# macOS ships shasum rather than coreutils' sha256sum. Both support the same
# -c check mode and the same record format.
sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

if [ "${1:-}" = "--check" ]; then
  if [ ! -f "$RECORD" ]; then
    echo "error: $RECORD is missing." >&2
    echo "       Generate it with: ./dev player icons" >&2
    exit 1
  fi
  if sha -c --status "$RECORD"; then
    echo "player web icons are current"
    exit 0
  fi
  echo "error: player web icons are stale." >&2
  echo "       A source SVG changed but the generated icons were not regenerated." >&2
  echo "       Mismatched sources:" >&2
  # The trailing `|| true` is load-bearing, not cosmetic. `sha -c` exits 1 here
  # by construction (it is reporting a mismatch), so under `set -e -o pipefail`
  # the whole pipeline fails and aborts the script on this line, swallowing the
  # "Fix with" hint below. Verified: without it the hint never prints.
  sha -c "$RECORD" 2>&1 | grep -v ': OK$' | sed 's/^/         /' >&2 || true
  echo "       Fix with: ./dev player icons" >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  echo "error: unknown argument '$1' (expected no arguments, or --check)" >&2
  exit 2
fi

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found." >&2
  echo "       Run this through './dev player icons' so it picks up librsvg" >&2
  echo "       from devenv.nix." >&2
  exit 1
fi

# render <source-svg> <size-px> <output-png>
render() {
  rsvg-convert --width "$2" --height "$2" --format png "$1" --output "$3"
  echo "  $3 (${2}x${2})"
}

echo "Regenerating player web icons from SVG sources..."

mkdir -p web/icons

# Favicon: SVG is the primary and is a verbatim copy of the app icon.
# The PNG exists only as a fallback for Safari below 16.4 and older browsers.
cp assets/icon.svg web/favicon.svg
echo "  web/favicon.svg (vector)"
render assets/icon.svg 32 web/favicon.png

# PWA icons. The maskable pair comes from the padded source so Android's and
# Chrome's circle mask cannot clip the squircle.
render assets/icon.svg 192 web/icons/Icon-192.png
render assets/icon.svg 512 web/icons/Icon-512.png
render assets/icon-maskable.svg 192 web/icons/Icon-maskable-192.png
render assets/icon-maskable.svg 512 web/icons/Icon-maskable-512.png

# Record what these were generated from so --check can detect drift later.
sha "${SOURCES[@]}" > "$RECORD"
echo "Recorded source hashes in $RECORD"
