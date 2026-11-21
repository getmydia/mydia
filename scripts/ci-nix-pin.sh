#!/usr/bin/env bash
#
# Refresh the master-<name> pins in the CI binary cache.
#
# Usage: scripts/ci-nix-pin.sh <all.json>
# Env:   NIX_CI_PUSH  push.sh, as exported by .github/actions/nix-ci
#        GITHUB_REF   must be refs/heads/master, or nothing is pushed
#
# <all.json> is ci-plan.sh's `all` list: [{"name", "out"}...], every check
# and ciInternal attribute with its output path. By the time the pins job
# runs every output is in cache.mydia.dev (PR runs pushed them, or this run's
# build jobs did), so one `nix-store --realise` only downloads. Each output
# is then pushed with its own pin; niks3 skips NARs it already has, so this
# mostly records the pin and restarts its retention clock.
#
# Pinning is upkeep, never a verdict on the code: anything missing or failing
# is a ::warning::, and the script always exits 0.
set -uo pipefail

all="$1"

# PRs never pin, whatever the calling job's `if` says.
if [ "${GITHUB_REF:-}" != "refs/heads/master" ]; then
  echo "::notice::pins skipped: ${GITHUB_REF:-<unset GITHUB_REF>} is not refs/heads/master"
  exit 0
fi

mapfile -t outs < <(jq -r '.[].out' "$all" | sort -u)
if [ "${#outs[@]}" -eq 0 ]; then
  echo "::notice::nothing to pin"
  exit 0
fi

# One call for every path; --keep-going fetches the rest when one is missing.
if ! nix-store --realise --keep-going "${outs[@]}" > /dev/null; then
  echo "::warning::some outputs could not be fetched from the cache; their pins are not refreshed"
fi

pinned=0
missing=0
while IFS=$'\t' read -r name out; do
  if [ -e "$out" ]; then
    NIKS3_PIN="master-$name" "$NIX_CI_PUSH" "$out" || true
    pinned=$((pinned + 1))
  else
    echo "::warning::master-$name not refreshed: $out is not in the cache"
    missing=$((missing + 1))
  fi
done < <(jq -r '.[] | [.name, .out] | @tsv' "$all")

echo "pins refreshed: $pinned, missing: $missing"
exit 0
