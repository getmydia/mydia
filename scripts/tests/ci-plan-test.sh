#!/usr/bin/env bash
#
# Assert scripts/ci-plan.sh holds its contract: no Nix, nix-eval-jobs is a
# stub on PATH that replays JSONL fixtures.
#
# The planner decides which flake checks CI builds. A check it wrongly calls
# cached is never built, and nothing else notices, so the selection rules are
# asserted directly.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/../.."

readonly SCRIPT="scripts/ci-plan.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/bin"
cat > "$tmp/bin/nix-eval-jobs" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *ciInternal*) cat "$FIXTURES/internal.jsonl" ;;
  *ciAndroid*) cat "$FIXTURES/android.jsonl" ;;
  *) cat "$FIXTURES/checks.jsonl" ;;
esac
exit "${STUB_EXIT:-0}"
STUB
chmod +x "$tmp/bin/nix-eval-jobs"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/calls" FIXTURES="$tmp/fx"
mkdir "$FIXTURES"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

expect_json() {
  local label="$1" want="$2" got="$3"
  want="$(jq -cS . <<<"$want")"
  got="$(jq -cS . <<<"$got" 2>/dev/null || printf '%s' "$got")"
  [ "$want" = "$got" ] || note_failure "$label:"$'\n'"  got    $got"$'\n'"  wanted $want"
}

# The build matrices alone; `all` has its own case.
matrices() { jq -c '{inputs, checks, nixos}' <<<"$1" 2>/dev/null || printf '%s' "$1"; }

# Store paths are fixture names, never real outputs.
drv() { printf '/nix/store/%032d-%s.drv' 0 "$1"; }
outp() { printf '/nix/store/%032d-%s' 1 "$1"; }

# One nix-eval-jobs line: job <attr> <cacheStatus> [neededBuild drv names...]
job() {
  local attr="$1" status="$2"
  shift 2
  local needed=()
  for n in "$@"; do needed+=("$(drv "$n")"); done
  jq -cn --arg attr "$attr" --arg status "$status" --arg drv "$(drv "$attr")" \
    --arg out "$(outp "$attr")" \
    --args '{attr: $attr, attrPath: [$attr], cacheStatus: $status,
             isCached: ($status != "notBuilt"), drvPath: $drv, outputs: {out: $out},
             neededBuilds: $ARGS.positional, neededSubstitutes: []}' "${needed[@]}"
}

# One ciInternal line: internal <attr> <drv name>
internal() {
  jq -cn --arg attr "$1" --arg drv "$(drv "$2")" --arg out "$(outp "$2")" \
    '{attr: $attr, attrPath: [$attr], drvPath: $drv, outputs: {out: $out}}'
}

write_internal() {
  {
    internal mixDepsCompiled-sqlite mix-deps-compiled
    internal mixDepsCompiled-postgres mix-deps-compiled
    internal mydiaTestBuild-sqlite mydia-test-build-sqlite
    internal mydiaTestBuild-postgres mydia-test-build-postgres
    internal dialyzer-plt dialyzer-plt
    internal nifs-mydia_subsync ci-nif-mydia_subsync
  } > "$FIXTURES/internal.jsonl"
}
write_internal

# The ciAndroid pass: the shell and the stamp. write_android <stamp status>
write_android() {
  {
    job shell notBuilt
    job stamp "$1"
  } > "$FIXTURES/android.jsonl"
}
write_android cached

# 1. Three checks, two cached: only the uncached one, no inputs.
{
  job ci-fileset-coverage cached
  job elixir-format notBuilt elixir-format mix-deps-compiled
  job rust-mydia_subsync-fmt cached
} > "$FIXTURES/checks.jsonl"
: > "$STUB_LOG"
out="$("$SCRIPT")" || note_failure "one uncached check: exited non-zero"
expect_json "one uncached check" \
  '{"inputs":[],"checks":[{"name":"elixir-format","attr":"checks.x86_64-linux.elixir-format","group":"lint"}],"nixos":[]}' \
  "$(matrices "$out")"
grep -q -- '--flake \.#checks\.x86_64-linux ' "$STUB_LOG" || note_failure "checks not evaluated from .#checks.x86_64-linux"
grep -q -- '--check-cache-status' "$STUB_LOG" || note_failure "--check-cache-status not passed"
grep -q -- '--force-recurse' "$STUB_LOG" || note_failure "--force-recurse not passed"
grep -q -- '--flake \.#legacyPackages\.x86_64-linux\.ciAndroid .*--check-cache-status' "$STUB_LOG" \
  || note_failure "ciAndroid not evaluated with --check-cache-status"
expect_json "cached stamp skips Build / Android" 'false' "$(jq -c .android <<<"$out")"

# 2. Shared inputs: a ciInternal derivation that 2+ uncached checks still need
#    is an input, named by its first alias; one needed by a single check, or a
#    shared derivation outside ciInternal, is not. "local" is not "cached".
#    The nixos group goes to its own list (outside the Nix / Checks verdict),
#    and its needs do not count toward inputs: dialyzer-plt is needed by
#    dialyzer and nixos-module, two checks, yet is no input, because the
#    blocking inputs wave must never build what only the NixOS tests need.
{
  job test-sqlite-1 notBuilt test-sqlite-1 mydia-test-build-sqlite mix-deps-compiled some-shared-tool
  job test-sqlite-2 notBuilt test-sqlite-2 mydia-test-build-sqlite mix-deps-compiled some-shared-tool
  job dialyzer notBuilt dialyzer dialyzer-plt mix-deps-compiled
  job test-postgres-1 notBuilt test-postgres-1 mydia-test-build-postgres
  job rust-server-test local
  job rust-mydia_subsync-test cached
  job relay-test notBuilt relay-test
  job nixos-module notBuilt nixos-module dialyzer-plt
  job nixos-module-postgres cached
  job zz-unknown notBuilt zz-unknown
} > "$FIXTURES/checks.jsonl"
out="$("$SCRIPT")" || note_failure "shared inputs: exited non-zero"
expect_json "shared inputs" '{
  "inputs": [
    {"name":"mixDepsCompiled-postgres","attr":"ciInternal.mixDepsCompiled-postgres","group":"other"},
    {"name":"mydiaTestBuild-sqlite","attr":"ciInternal.mydiaTestBuild-sqlite","group":"other"}
  ],
  "checks": [
    {"name":"dialyzer","attr":"checks.x86_64-linux.dialyzer","group":"lint"},
    {"name":"relay-test","attr":"checks.x86_64-linux.relay-test","group":"relay"},
    {"name":"rust-server-test","attr":"checks.x86_64-linux.rust-server-test","group":"server"},
    {"name":"test-postgres-1","attr":"checks.x86_64-linux.test-postgres-1","group":"postgres"},
    {"name":"test-sqlite-1","attr":"checks.x86_64-linux.test-sqlite-1","group":"sqlite"},
    {"name":"test-sqlite-2","attr":"checks.x86_64-linux.test-sqlite-2","group":"sqlite"},
    {"name":"zz-unknown","attr":"checks.x86_64-linux.zz-unknown","group":"other"}
  ],
  "nixos": [
    {"name":"nixos-module","attr":"checks.x86_64-linux.nixos-module","group":"nixos"}
  ]
}' "$(matrices "$out")"

# 2b. A ciInternal derivation both NixOS checks need, and nothing else, is
#     still no input: it builds inside the NixOS jobs, never in the wave in
#     front of the blocking checks.
{
  job nixos-module notBuilt nixos-module mydia-test-build-postgres
  job nixos-module-postgres notBuilt nixos-module-postgres mydia-test-build-postgres
  job elixir-format notBuilt elixir-format
} > "$FIXTURES/checks.jsonl"
out="$("$SCRIPT")" || note_failure "nixos-only input: exited non-zero"
expect_json "nixos-only input" '{
  "inputs": [],
  "checks": [{"name":"elixir-format","attr":"checks.x86_64-linux.elixir-format","group":"lint"}],
  "nixos": [
    {"name":"nixos-module","attr":"checks.x86_64-linux.nixos-module","group":"nixos"},
    {"name":"nixos-module-postgres","attr":"checks.x86_64-linux.nixos-module-postgres","group":"nixos"}
  ]
}' "$(matrices "$out")"

# 3. Everything cached: both matrices empty, printed as [] so the workflow's
#    empty-matrix guards match; `all` still lists every check and every
#    ciInternal attribute (aliases included) with its output path, for pins,
#    plus the Android stamp and never the Android shell, whose closure holds
#    the unfree SDK.
{
  job elixir-format cached
  job test-sqlite-1 cached
} > "$FIXTURES/checks.jsonl"
out="$("$SCRIPT")" || note_failure "all cached: exited non-zero"
grep -q '"inputs":\[\],"checks":\[\],"nixos":\[\],' <<<"$out" || note_failure "all cached: got '$out', wanted compact empty matrices"
expect_json "all for pins" "$(jq -cn --arg o "$(outp '')" '[
  {name: "dialyzer-plt", out: "\($o)dialyzer-plt"},
  {name: "elixir-format", out: "\($o)elixir-format"},
  {name: "mixDepsCompiled-postgres", out: "\($o)mix-deps-compiled"},
  {name: "mixDepsCompiled-sqlite", out: "\($o)mix-deps-compiled"},
  {name: "mydiaTestBuild-postgres", out: "\($o)mydia-test-build-postgres"},
  {name: "mydiaTestBuild-sqlite", out: "\($o)mydia-test-build-sqlite"},
  {name: "nifs-mydia_subsync", out: "\($o)ci-nif-mydia_subsync"},
  {name: "android-stamp", out: "\($o)stamp"},
  {name: "test-sqlite-1", out: "\($o)test-sqlite-1"}
] | sort_by(.name)')" "$(jq -c .all <<<"$out")"

# 3a. A stamp the cache lacks ("local" included) runs Build / Android; a
#     ciAndroid pass without a stamp fails the plan rather than skipping it.
for status in notBuilt local; do
  write_android "$status"
  out="$("$SCRIPT")" || note_failure "uncached stamp ($status): exited non-zero"
  expect_json "uncached stamp ($status) runs Build / Android" 'true' "$(jq -c .android <<<"$out")"
done
{ job shell notBuilt; } > "$FIXTURES/android.jsonl"
if "$SCRIPT" >/dev/null 2>&1; then
  note_failure "missing stamp: exited zero"
fi
write_android cached

# 3b. A ciInternal entry without a drvPath is ignored, not fatal.
{
  cat "$FIXTURES/internal.jsonl"
  jq -cn '{attr: "noDrv", attrPath: ["noDrv"]}'
} > "$FIXTURES/internal.jsonl.new"
mv "$FIXTURES/internal.jsonl.new" "$FIXTURES/internal.jsonl"
{
  job test-sqlite-1 notBuilt test-sqlite-1 mydia-test-build-sqlite
  job test-sqlite-2 notBuilt test-sqlite-2 mydia-test-build-sqlite
} > "$FIXTURES/checks.jsonl"
out="$("$SCRIPT")" || note_failure "entry without drvPath: exited non-zero"
expect_json "entry without drvPath" '["mydiaTestBuild-sqlite"]' "$(jq -c '.inputs | map(.name)' <<<"$out")"
if jq -e '.all | any(.name == "noDrv")' <<<"$out" >/dev/null; then
  note_failure "entry without drvPath or outputs listed for pins"
fi
write_internal

# 4. Group classification of the real check name prefixes.
{
  for name in test-sqlite-3 test-postgres-2 elixir-lint ci-fileset-coverage \
    rust-mydia_p2p-clippy rust-p2p-core-wasm rust-plugins rust-server-fmt \
    nixos-module-postgres; do
    job "$name" notBuilt "$name"
  done
} > "$FIXTURES/checks.jsonl"
out="$("$SCRIPT")" || note_failure "groups: exited non-zero"
expect_json "groups" \
  '{"ci-fileset-coverage":"lint","elixir-lint":"lint","nixos-module-postgres":"nixos","rust-mydia_p2p-clippy":"rust","rust-p2p-core-wasm":"rust","rust-plugins":"rust","rust-server-fmt":"server","test-postgres-2":"postgres","test-sqlite-3":"sqlite"}' \
  "$(jq -c '.checks + .nixos | map({(.name): .group}) | add' <<<"$out")"

# 5. An evaluation error fails the plan and names the attribute.
{
  job elixir-format notBuilt elixir-format
  jq -cn '{attr: "test-sqlite-1", attrPath: ["test-sqlite-1"], error: "deps.nix is stale"}'
} > "$FIXTURES/checks.jsonl"
if err="$("$SCRIPT" 2>&1 >/dev/null)"; then
  note_failure "eval error: exited zero"
fi
grep -q '^::error::.*test-sqlite-1.*deps.nix is stale' <<<"$err" || note_failure "eval error: no ::error:: naming the attribute"

# 6. nix-eval-jobs itself failing fails the plan.
{ job elixir-format notBuilt elixir-format; } > "$FIXTURES/checks.jsonl"
if STUB_EXIT=1 "$SCRIPT" >/dev/null 2>&1; then
  note_failure "nix-eval-jobs failure: exited zero"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ci-plan-test.sh: ok"
