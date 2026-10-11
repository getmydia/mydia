#!/usr/bin/env bash
# Fetches the pinned Prowlarr commit into .prowlarr/ and verifies it.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
read -r tag sha < "$here/PROWLARR_REF"
dest="$here/.prowlarr"

if [ -d "$dest/.git" ] && [ "$(git -C "$dest" rev-parse HEAD)" = "$sha" ]; then
  exit 0
fi

rm -rf "$dest"
git init -q "$dest"
git -C "$dest" remote add origin https://github.com/Prowlarr/Prowlarr.git
git -C "$dest" fetch -q --depth 1 origin "$sha"
git -C "$dest" checkout -q FETCH_HEAD

actual="$(git -C "$dest" rev-parse HEAD)"
if [ "$actual" != "$sha" ]; then
  echo "Prowlarr checkout is $actual, expected $sha ($tag)" >&2
  exit 1
fi
