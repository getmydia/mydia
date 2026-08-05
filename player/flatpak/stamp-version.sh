#!/usr/bin/env bash
# Stamps a release version into the two files the Flatpak build reads it from.
# Run from the repository root, on the host, before flatpak-builder copies the
# tree into the sandbox.
#
# Usage: player/flatpak/stamp-version.sh <version> <version_code> <iso_date>
set -euo pipefail

VERSION="${1:?version required (e.g. 1.2.3)}"
VERSION_CODE="${2:?version_code required (e.g. 10042)}"
DATE="${3:?ISO date required (e.g. 2026-08-04)}"

METAINFO="player/flatpak/dev.mydia.player.metainfo.xml"

# Same rewrite the player-linux job in release.yml already performs.
sed -i "s/^version: .*/version: ${VERSION}+${VERSION_CODE}/" player/pubspec.yaml

# Replace the whole <releases> block rather than appending, so repeated runs
# are idempotent and the committed 0.0.0 placeholder never ships.
python3 - "$METAINFO" "$VERSION" "$DATE" <<'PY'
import re
import sys

path, version, date = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as fh:
    xml = fh.read()

block = f'  <releases>\n    <release version="{version}" date="{date}"/>\n  </releases>'
xml, count = re.subn(r"  <releases>.*?</releases>", block, xml, flags=re.DOTALL)
if count != 1:
    sys.exit(f"expected exactly one <releases> block in {path}, replaced {count}")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(xml)
PY

echo "Stamped ${VERSION}+${VERSION_CODE} (${DATE})"
