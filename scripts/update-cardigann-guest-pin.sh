#!/usr/bin/env bash
# Points nix/ci/cardigann-guest.json at the published Cardigann guest for the
# current guest sources, so the sandboxed test shards (nix/ci/tests.nix) can
# run the :cardigann_wasm tests without network.
#
#   scripts/update-cardigann-guest-pin.sh            # hash from mix
#   scripts/update-cardigann-guest-pin.sh <hash>     # hash given (CI)
#
# The hash is `mix mydia.cardigann_guest hash`. CI passes the value its build
# job computed with native/cardigann_guest/scripts/source-hash.sh, which a
# test keeps equal to the mix task. Fails when the release
# cardigann-guest-<hash> is not published (a draft is a failed run) or when
# its .sha256 sidecar disagrees with the digest GitHub recorded for the
# asset. Needs gh, jq and curl.
set -euo pipefail

cd "$(dirname "$0")/.."

repo="${GH_REPO:-getmydia/mydia}"
hash="${1:-$(mix mydia.cardigann_guest hash | tail -n 1)}"

if ! [[ "$hash" =~ ^[0-9a-f]{16}$ ]]; then
  echo "not a Cardigann guest source hash: $hash" >&2
  exit 1
fi

tag="cardigann-guest-$hash"
name="cardigann-$hash.wasm"

release="$(gh release view "$tag" --repo "$repo" --json isDraft,assets)"
if [ "$(jq -r .isDraft <<<"$release")" != "false" ]; then
  echo "$tag is a draft (a failed publish run); not pinning it" >&2
  exit 1
fi

asset() { jq -r --arg n "$1" '.assets[] | select(.name == $n) | .'"$2" <<<"$release"; }

url="$(asset "$name" url)"
sidecar_url="$(asset "$name.sha256" url)"
if [ -z "$url" ] || [ -z "$sidecar_url" ]; then
  echo "$tag has no $name or $name.sha256" >&2
  exit 1
fi

sha256="$(curl -fsSL "$sidecar_url" | tr -d '[:space:]')"
if ! [[ "$sha256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "$name.sha256 is not a SHA-256: $sha256" >&2
  exit 1
fi

digest="$(asset "$name" digest)"
if [ -n "$digest" ] && [ "$digest" != "sha256:$sha256" ]; then
  echo "$name.sha256 ($sha256) disagrees with the asset digest ($digest)" >&2
  exit 1
fi

jq -n --arg source_hash "$hash" --arg url "$url" --arg sha256 "$sha256" \
  '{source_hash: $source_hash, url: $url, sha256: $sha256}' \
  > nix/ci/cardigann-guest.json

echo "Pinned $name ($sha256) in nix/ci/cardigann-guest.json"
