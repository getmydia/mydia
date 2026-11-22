#!/usr/bin/env bash
#
# Plan a CI run of the flake checks: print the build matrices as JSON.
#
# Usage: scripts/ci-plan.sh [flake]          (flake defaults to .)
# Env:   CI_PLAN_SYSTEM   default x86_64-linux
#        CI_PLAN_WORKERS  nix-eval-jobs workers, default 2
#
# Output (stdout, one compact line):
#
#   {"inputs":[{"name","attr","group"}...],"checks":[{"name","attr","group"}...],
#    "nixos":[{"name","attr","group"}...],"android":true|false,
#    "all":[{"name","out"}...]}
#
# `attr` is what the workflow passes to `nix build .#<attr>`.
#
# all: every check and every ciInternal attribute (aliases included), cached
#   or not, with its output path ("out", or the first output), plus
#   ciAndroid.stamp as `android-stamp`, for the master-only pins job, which
#   refreshes the `master-<name>` pins without evaluating again.
#   ciAndroid.shell is left out on purpose: its closure holds the unfree
#   Android SDK, which must never be pushed (nix/ci/android.nix).
#
# android: true when the cache lacks `legacyPackages.<system>.ciAndroid.stamp`,
#   the marker Build / Android pushes once the APK built from exactly these
#   inputs (nix/ci/android.nix). False skips the job.
#
# checks: every `checks.<system>.*` attribute whose cacheStatus, from
#   `nix-eval-jobs --check-cache-status`, is not "cached". nix-eval-jobs
#   reports "cached" (in a configured substituter), "local" (in this store
#   only) or "notBuilt". "local" is kept on purpose: on a fresh runner it
#   means the cache lacks the path, and building it is a no-op that lets the
#   build job push it. The `nixos` group (the NixOS module VM tests) is not
#   in this list: see nixos.
#
# nixos: the uncached checks of the `nixos` group, selected the same way.
#   The workflow builds them in their own matrix, which the `Nix / Checks`
#   verdict does not include: a QEMU boot is the slowest and flakiest build
#   in the set. (They were also kept apart because the package they boot took
#   the whole repo as source and reran on nearly every commit; it now takes
#   the `mydiaPackage` file set, so that reason is gone, but which jobs run
#   is unchanged.) Their needs do not count
#   toward `inputs`: the inputs wave sits in front of the blocking checks,
#   so a derivation only the NixOS tests need (the packages) must never
#   build or fail there. The NixOS jobs build it themselves.
#
# inputs: the `ciInternal` derivations (compiled deps, test builds, the
#   Dialyzer PLT, NIFs, plugin wasm, ...) that two or more of those checks
#   still need, so the workflow builds each once, in a wave before the checks,
#   instead of once per check. "Still need" is each check's `neededBuilds`:
#   nix-eval-jobs fills it from the store's query-missing walk over the check's
#   whole build closure, so it is transitive (a test shard needs
#   mixDepsCompiled through mydiaTestBuild) and already excludes anything a
#   substituter has. That is `nix-store -q --requisites` of the check's .drv
#   intersected with the uncached paths, computed by Nix itself in the same
#   pass, so the planner needs no further store queries. The drv-to-name map
#   comes from a second nix-eval-jobs pass over
#   `legacyPackages.<system>.ciInternal`; a derivation exposed under two names
#   (mixDepsCompiled-sqlite and -postgres are one derivation) is listed once,
#   under the alphabetically first. A ciInternal entry without a drvPath is
#   ignored rather than allowed to break the map.
#
# group: the check family, from the name prefix (sqlite, postgres, lint,
#   rust, relay, server, nixos, other), for aggregators that filter results.
#
# An evaluation error on any attribute fails the plan with a ::error::
# annotation naming it.
set -euo pipefail

flake="${1:-.}"
system="${CI_PLAN_SYSTEM:-x86_64-linux}"
workers="${CI_PLAN_WORKERS:-2}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# run_eval_jobs <out-file> <flake attr> [extra args...]
run_eval_jobs() {
  local out="$1" attr="$2"
  shift 2
  local status=0
  nix-eval-jobs --flake "$flake#$attr" --force-recurse --workers "$workers" "$@" > "$out" || status=$?

  jq -r 'select(has("error"))
    | "::error::nix-eval-jobs failed on \(.attr // (.attrPath // [] | join("."))): \(.error | gsub("\n"; "%0A"))"' \
    "$out" >&2
  if [ "$status" -ne 0 ] || jq -e -s 'any(has("error"))' "$out" > /dev/null; then
    echo "ci-plan.sh: evaluating $flake#$attr failed (nix-eval-jobs exit $status)" >&2
    exit 1
  fi
}

run_eval_jobs "$tmp/checks.jsonl" "checks.$system" --check-cache-status
run_eval_jobs "$tmp/internal.jsonl" "legacyPackages.$system.ciInternal"
run_eval_jobs "$tmp/android.jsonl" "legacyPackages.$system.ciAndroid" --check-cache-status

jq -c -n --arg system "$system" \
  --slurpfile checks "$tmp/checks.jsonl" \
  --slurpfile internal "$tmp/internal.jsonl" \
  --slurpfile android "$tmp/android.jsonl" '
  def group:
    if test("^test-sqlite-") then "sqlite"
    elif test("^test-postgres-") then "postgres"
    elif test("^rust-server-") then "server"
    elif test("^rust-") then "rust"
    elif test("^relay-") then "relay"
    elif test("^nixos-") then "nixos"
    elif test("^(elixir-|dialyzer$|ci-)") then "lint"
    else "other" end;

  def out_path: .outputs.out // ((.outputs // {}) | to_entries | first | .value?);

  ($android | map(select(.attr == "stamp")) | first) as $stamp
  | if $stamp == null then error("legacyPackages.\($system).ciAndroid has no stamp") else . end
  | ($checks | map(select(.cacheStatus != "cached"))) as $uncached
  | ($internal
      | map(select(.drvPath))
      | group_by(.drvPath)
      | map({key: .[0].drvPath, value: (map(.attr) | sort | first)})
      | from_entries) as $nameOf
  | ($uncached
      | map(select(.attr | group != "nixos"))
      | map(.neededBuilds // [] | map(select($nameOf[.] != null)) | unique)
      | add // []
      | group_by(.)
      | map(select(length >= 2) | $nameOf[first])
      | sort) as $inputs
  | ($uncached | map(.attr) | sort
      | map({name: ., attr: "checks.\($system).\(.)", group: group})) as $built
  | {
      inputs: ($inputs | map({name: ., attr: "ciInternal.\(.)", group: group})),
      checks: ($built | map(select(.group != "nixos"))),
      nixos: ($built | map(select(.group == "nixos"))),
      android: ($stamp.cacheStatus != "cached"),
      all: ($checks + $internal + [$stamp | .attr = "android-stamp"]
              | map({name: .attr, out: out_path} | select(.out))
              | sort_by(.name))
    }'
