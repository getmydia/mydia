#!/usr/bin/env bash
#
# Upload one dev build to the mydia-dev-builds bucket (served at
# https://dl.mydia.dev) and record it in the bucket's index.json, which
# scripts/appcast reads to build the dev track of releases.json and the dev
# channel of the Sparkle appcast.
#
# Called by player-android.yml and player-macos.yml, so it runs on Ubuntu and
# on the macOS runner alike: keep it to bash 3.2 and BSD-compatible tools
# (wc -c, shasum; never stat -c, sha256sum, mapfile or declare -A).
# scripts/dev-builds/publish-test.sh enforces that.
#
# Configured by environment:
#   DEV_BUILD_PLATFORM  required, e.g. android or macos
#   DEV_BUILD_SOURCE    required, the local file to upload
#   DEV_BUILD_FILE      required, its object path in the bucket, e.g.
#                       macos/mydia-player-macos-v1.2.3-dev.4.dmg
#   DEV_BUILD_VERSION   required, the version string
#   DEV_BUILD_NUMBER    required, the integer build number
#   DEV_BUILD_EXTRA     optional JSON object merged into the index entry
#   DEV_BUILDS_REMOTE   optional rclone destination root. Unset means R2,
#                       which needs R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and
#                       R2_SECRET_ACCESS_KEY. Tests point it at a directory.
set -euo pipefail

for var in DEV_BUILD_PLATFORM DEV_BUILD_SOURCE DEV_BUILD_FILE DEV_BUILD_VERSION DEV_BUILD_NUMBER; do
  if [ -z "${!var:-}" ]; then
    echo "::error::${var} is required to publish a dev build."
    exit 1
  fi
done

PLATFORM="$DEV_BUILD_PLATFORM"
SOURCE="$DEV_BUILD_SOURCE"
OWN_FILE="$DEV_BUILD_FILE"
VERSION="$DEV_BUILD_VERSION"
VERSION_CODE="$DEV_BUILD_NUMBER"
EXTRA="${DEV_BUILD_EXTRA:-}"
[ -n "$EXTRA" ] || EXTRA='{}'

if [ ! -f "$SOURCE" ]; then
  echo "::error::${SOURCE} does not exist, so there is no dev build to publish."
  exit 1
fi
if ! jq -e 'type == "object"' <<<"$EXTRA" > /dev/null 2>&1; then
  echo "::error::DEV_BUILD_EXTRA must be a JSON object, got: ${EXTRA}"
  exit 1
fi

if [ -n "${DEV_BUILDS_REMOTE:-}" ]; then
  REMOTE="$DEV_BUILDS_REMOTE"
else
  if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
    echo "::error::R2 credentials are incomplete (R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY are all required), so the dev build cannot be published."
    exit 1
  fi

  # The token is scoped to object read/write on one bucket and cannot
  # ListBuckets, which rclone's default config probes for. Same shape as the
  # Flatpak publish in release.yml.
  mkdir -p ~/.config/rclone
  cat > ~/.config/rclone/rclone.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
  REMOTE="r2:mydia-dev-builds"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

SIZE=$(wc -c < "$SOURCE" | tr -d ' ')
SHA=$(shasum -a 256 "$SOURCE" | cut -d' ' -f1)

# Attempt 1 of an APK upload has been observed to fail with a transient
# "NotImplemented: Not Implemented" from R2 (rclone 1.60.1 from Ubuntu's apt,
# a 109 MiB APK), then succeed on attempt 2 with nothing else changed. This is
# not a multipart-threshold problem: R2's own limits documentation
# (developers.cloudflare.com/r2/platform/limits/) puts the single-part
# PutObject cap at ~5 GiB, far above any build this produces, and a search of
# rclone's changelog between v1.60.0 and v1.65.0 found no fix matching this
# symptom, so there is no specific rclone version or flag to point at
# instead. What actually recovered it is rclone's own default `--retries=3`
# (`rclone help flags`), already active here with no flags of its own, which
# retries the whole `copyto` up to twice more on failure. Community reports
# describe assorted transient R2-side errors (403s, signature failures,
# NotImplemented) across many rclone versions with no single client-side bug
# behind them, consistent with edge-node flakiness on R2's side rather than a
# defect here. This runs once per manually dispatched dev build, not in a hot
# path, so relying on the existing default instead of an unproven flag or a
# version pin is the accepted trade-off, not an oversight.
rclone copyto "$SOURCE" "${REMOTE}/${OWN_FILE}"

# Read, amend, write. The index is small and only the dev build publishers
# write it (serialised by the mydia-dev-builds-index concurrency group in
# player-ondemand.yml), so a read-modify-write is safe and avoids a bucket
# listing the scoped token may not allow.
#
# The exit code alone cannot say whether an index already exists. Against a
# local filesystem rclone exits 3 for a missing directory and 4 for a missing
# file, but against R2 (S3) a missing object exits 0 and writes nothing at
# all: this bit a real publish, whose bucket was empty on its very first run,
# so `index.json` came back a zero-byte file, the case below took the `0)`
# branch, and the survival check below failed on an index that never
# described anything. So the case here only separates "worth inspecting
# further" (0, 3, 4) from a genuine read failure; the actual bootstrap
# decision is made afterward by checking what index.json actually contains,
# not by trusting any exit code. Any other exit is a real read failure, and
# treating it as "no index yet" would clobber the bucket's real index with one
# built from an empty base, dropping every previously tracked build, so that
# case still fails loudly instead of guessing.
set +e
rclone cat "${REMOTE}/index.json" > "$work/index.json" 2> "$work/rclone-cat.err"
RCLONE_CAT_RC=$?
set -e
case "$RCLONE_CAT_RC" in
  0|3|4) ;;
  *)
    cat "$work/rclone-cat.err" >&2
    echo "::error::Could not read the existing index.json (rclone exit ${RCLONE_CAT_RC}). Leaving the bucket's index untouched."
    exit 1
    ;;
esac

# index.json might be empty, absent, `{}`, or otherwise not shaped like an
# index, whatever the exit code said. Bootstrap whenever it is not a JSON
# object with a .builds array; only a genuinely populated, well-formed index
# is used as-is.
if ! jq -e 'type == "object" and has("builds") and (.builds | type == "array")' "$work/index.json" > /dev/null 2>&1; then
  echo '{"builds":[]}' > "$work/index.json"
fi

# The container can be a well-formed {"builds": [...]} array while still
# holding a malformed element inside it: a null, a bare string, or an object
# missing platform, build, or file. That entry survives the check above, then
# `-.build` below throws on anything that is not a number, and set -e stops
# the script before rclone copyto ever writes the index back, wedging every
# future publish behind one bad row that only manual bucket surgery can clear.
# Drop malformed entries instead of failing the whole index, using the same
# three required fields the feed generator does (isWellFormedDevBuild in
# scripts/appcast/lib/releases-json.mjs: a string platform, a number build, a
# string file), so this never accepts what the generator would silently
# reject anyway. Filtering here, before the amend below, means the prune and
# the survival check both run against the cleaned set, so a genuine prune loss
# is still refused correctly even when the index it is competing against also
# had junk in it. jq's `type` (unlike JS's `typeof`) already reports "null"
# for null, so the object check alone excludes it without a separate null
# test, and short-circuiting `and` means a non-object entry is never indexed
# into, so this cannot itself throw on the very values it is filtering out.
WELL_FORMED='type == "object" and (.platform | type == "string") and (.build | type == "number") and (.file | type == "string")'
jq -c ".builds[] | select(($WELL_FORMED) | not)" "$work/index.json" | while IFS= read -r bad; do
  echo "::warning::Dropping malformed dev build index entry (missing or mistyped platform, build, or file): ${bad}"
done
jq ".builds |= map(select($WELL_FORMED))" "$work/index.json" > "$work/index.clean.json"
mv "$work/index.clean.json" "$work/index.json"

# A re-dispatch of the same version replaces that platform's entry; the other
# platform's entry for the same version is left alone.
jq --arg platform "$PLATFORM" \
   --arg version "$VERSION" \
   --argjson build "$VERSION_CODE" \
   --arg file "$OWN_FILE" \
   --argjson size "$SIZE" \
   --arg sha "$SHA" \
   --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --argjson extra "$EXTRA" \
   '{builds: ([{platform: $platform, version: $version, build: $build, file: $file, size: $size, sha256: $sha, published_at: $published} + $extra]
              + [.builds[] | select(.platform != $platform or .version != $version)])
             | sort_by(-.build) }' "$work/index.json" > "$work/index.next.json"

# Keep the newest five per platform, so platforms never evict each other.
jq '{builds: [.builds | group_by(.platform)[] | sort_by(-.build) | .[0:5]] | flatten | sort_by(-.build)}' \
  "$work/index.next.json" > "$work/index.kept.json"

# If this run's own build did not survive the prune, refuse rather than
# silently discard it or hide it from the index. The file is already uploaded
# and is left in place; it is simply never deleted or indexed by this run.
if ! jq -e --arg file "$OWN_FILE" '.builds | any(.file == $file)' "$work/index.kept.json" > /dev/null; then
  LOWEST_KEPT=$(jq -r --arg platform "$PLATFORM" '[.builds[] | select(.platform == $platform) | .build] | min' "$work/index.kept.json")
  echo "::error::Build ${VERSION_CODE} (version ${VERSION}) is older than the five newest ${PLATFORM} builds already published (lowest kept build: ${LOWEST_KEPT}). Publishing it would either discard it or hide it from the index, so refusing."
  exit 1
fi

# Write the index first, then delete the objects it no longer references:
# builds pruned from the kept set, and an earlier upload of a version this
# run replaced under a different key (macOS keys carry the DMG digest, so a
# re-dispatch never overwrites bytes a signed feed entry still describes).
# Deleting only after the write means a failed write leaves every object the
# old index and the deployed feed point at in place. The just-uploaded file
# is excluded explicitly, whatever the ranking says, even though the check
# above already guarantees it survived.
rclone copyto "$work/index.kept.json" "${REMOTE}/index.json"

jq -r --slurpfile kept "$work/index.kept.json" --arg own "$OWN_FILE" \
  '[.builds[].file] - [$kept[0].builds[].file] - [$own] | unique | .[]' \
  "$work/index.json" > "$work/dropped.txt"
while read -r file; do
  if [ -n "$file" ]; then
    rclone deletefile "${REMOTE}/${file}" || echo "::warning::Failed to delete stale build ${file}; it may need manual cleanup."
  fi
done < "$work/dropped.txt"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Published ${OWN_FILE} (build ${VERSION_CODE})." >> "$GITHUB_STEP_SUMMARY"
fi
