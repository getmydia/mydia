#!/usr/bin/env bash
#
# Rasterise the beta and dev channel icons to the PNGs flutter_launcher_icons
# reads. Local only: CI uses the committed PNGs, so runners need no rsvg.
#
#   tool/gen-channel-icons.sh
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

for ch in beta dev; do
  rsvg-convert -w 1024 -h 1024 "assets/icon-$ch.svg" -o "assets/icon-$ch.png"
  rsvg-convert -w 1024 -h 1024 -b '#3b82f6' "assets/icon_ios-$ch.svg" -o "assets/icon_ios-$ch.png"
done
echo "gen-channel-icons: wrote assets/icon{,_ios}-{beta,dev}.png"
