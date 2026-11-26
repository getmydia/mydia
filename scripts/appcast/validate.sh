#!/usr/bin/env bash
# Independent check on the merged feed, run after generate.mjs has written it.
#
# This deliberately duplicates some of assertFeedInvariants: a generator bug
# must not be able to wave its own output through. It is also the per-item form
# of the whole-file greps release.yml uses on the single-item per-release
# appcast, which would pass a merged feed where one item carried two signatures
# and another carried none.
set -euo pipefail

FEED="${1:?usage: validate.sh <appcast.xml>}"

if ! command -v xmllint >/dev/null 2>&1; then
  echo "::error::xmllint not found; cannot validate the merged appcast"
  exit 1
fi

xmllint --noout "$FEED"

# count() prints a float on some libxml2 builds ("2.000000") and an integer on
# others. Truncating at the decimal point handles both; without it the [ -lt ]
# below dies with "integer expression expected" on exactly the builds that pad.
count_xpath() {
  xmllint --xpath "$1" "$FEED" | cut -d. -f1
}

item_count=$(count_xpath 'count(/rss/channel/item)')
if [ "$item_count" -lt 1 ]; then
  echo "::error::merged appcast has no items"
  exit 1
fi

for i in $(seq 1 "$item_count"); do
  enclosures=$(count_xpath "count(/rss/channel/item[$i]/enclosure)")
  sigs=$(count_xpath "count(/rss/channel/item[$i]/enclosure/@*[local-name()='edSignature'])")
  lengths=$(count_xpath "count(/rss/channel/item[$i]/enclosure/@length)")

  if [ "$enclosures" -ne 1 ] || [ "$sigs" -ne 1 ] || [ "$lengths" -ne 1 ]; then
    echo "::error::item $i malformed: enclosure=$enclosures edSignature=$sigs length=$lengths (expected 1 each)"
    xmllint --format "$FEED"
    exit 1
  fi
done

# xmllint --xpath cannot resolve the sparkle: prefix without a namespace
# declaration on the command line, so this matches on local-name() instead.
# A stable-channel client only ever sees channel-less items, so a feed with
# none silently tells every stable install "no updates available" forever.
stable_count=$(count_xpath "count(/rss/channel/item[not(*[local-name()='channel'])])")
if [ "$stable_count" -lt 1 ]; then
  echo "::error::merged appcast has no channel-less (stable) item; every stable-channel client would see no updates"
  exit 1
fi

# A file served from the dev build bucket must only reach clients on the dev
# track. Without the channel element Sparkle offers the item to everyone, so a
# stable install would be handed a dev build. Checked here independently of
# assertFeedInvariants, for the reason given at the top of this file.
dev_url="starts-with(@url,'https://dl.mydia.dev/')"
dev_count=$(count_xpath "count(/rss/channel/item[enclosure[$dev_url]])")
unchanneled_dev=$(count_xpath "count(/rss/channel/item[enclosure[$dev_url] and not(*[local-name()='channel' and normalize-space(text())='dev'])])")
if [ "$unchanneled_dev" -ne 0 ]; then
  echo "::error::$unchanneled_dev item(s) served from dl.mydia.dev lack the dev channel; stable clients would be offered a dev build"
  exit 1
fi

echo "merged appcast validated: $item_count item(s), $stable_count stable, $dev_count dev"
