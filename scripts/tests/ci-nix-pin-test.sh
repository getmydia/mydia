#!/usr/bin/env bash
#
# Assert scripts/ci-nix-pin.sh holds its contract: no Nix, no network.
# nix-store and the push script are stubs; "store paths" live in a temp dir.
#
# The pins job is master upkeep and must never fail a run, while still
# pinning everything it can, one pin per attribute.
set -euo pipefail
export LC_ALL=C.UTF-8

cd "$(dirname "$0")/../.."

readonly SCRIPT="scripts/ci-nix-pin.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/bin" "$tmp/store"
# Realises (creates) every requested path listed in STUB_AVAILABLE; fails,
# like nix-store, when any requested path is not available.
cat > "$tmp/bin/nix-store" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
status=0
for arg in "$@"; do
  case "$arg" in --*) continue ;; esac
  if grep -qxF "$arg" <<<"$STUB_AVAILABLE"; then touch "$arg"; else status=1; fi
done
exit "$status"
STUB
cat > "$tmp/bin/push" <<'STUB'
#!/usr/bin/env bash
echo "${NIKS3_PIN:-} $*" >> "$PUSH_LOG"
exit "${PUSH_EXIT:-0}"
STUB
chmod +x "$tmp/bin/nix-store" "$tmp/bin/push"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/calls" PUSH_LOG="$tmp/pushes" NIX_CI_PUSH="$tmp/bin/push"
export GITHUB_REF=refs/heads/master

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

s="$tmp/store"
# Two names share one output (an alias), as mixDepsCompiled-{sqlite,postgres} do.
jq -n --arg s "$s" '[
  {name: "test-sqlite-1", out: "\($s)/a-test-sqlite-1"},
  {name: "mixDepsCompiled-sqlite", out: "\($s)/b-deps"},
  {name: "mixDepsCompiled-postgres", out: "\($s)/b-deps"}
]' > "$tmp/all.json"

reset() { rm -f "$s"/* "$STUB_LOG" "$PUSH_LOG"; touch "$STUB_LOG" "$PUSH_LOG"; }

# 1. Everything substitutable: one realise call for the unique paths, one
#    push per attribute, each with its own master-<name> pin.
reset
out="$(STUB_AVAILABLE="$s/a-test-sqlite-1"$'\n'"$s/b-deps" "$SCRIPT" "$tmp/all.json" 2>&1)" \
  || note_failure "all available: exited non-zero"
[ "$(wc -l < "$STUB_LOG")" -eq 1 ] || note_failure "expected one nix-store call, got $(wc -l < "$STUB_LOG")"
grep -q -- '--realise --keep-going' "$STUB_LOG" || note_failure "nix-store not called with --realise --keep-going"
[ "$(grep -o "$s/b-deps" "$STUB_LOG" | wc -l)" -eq 1 ] || note_failure "aliased output realised more than once"
expected="master-mixDepsCompiled-postgres $s/b-deps
master-mixDepsCompiled-sqlite $s/b-deps
master-test-sqlite-1 $s/a-test-sqlite-1"
[ "$(sort "$PUSH_LOG")" = "$expected" ] || note_failure "pushes:"$'\n'"$(cat "$PUSH_LOG")"
if grep -q '^::warning::' <<<"$out"; then note_failure "warning when everything was available"; fi

# 2. One output missing from the cache: warn for it, pin the rest, exit 0.
reset
out="$(STUB_AVAILABLE="$s/b-deps" "$SCRIPT" "$tmp/all.json" 2>&1)" \
  || note_failure "one missing: exited non-zero"
grep -q '^::warning::master-test-sqlite-1 not refreshed' <<<"$out" || note_failure "no warning naming the missing pin"
[ "$(wc -l < "$PUSH_LOG")" -eq 2 ] || note_failure "expected the 2 available pins pushed, got $(wc -l < "$PUSH_LOG")"

# 3. A failing push still exits 0 and goes on to the next attribute.
reset
STUB_AVAILABLE="$s/a-test-sqlite-1"$'\n'"$s/b-deps" PUSH_EXIT=1 "$SCRIPT" "$tmp/all.json" > /dev/null 2>&1 \
  || note_failure "failing push: exited non-zero"
[ "$(wc -l < "$PUSH_LOG")" -eq 3 ] || note_failure "a failing push stopped the loop"

# 4. An empty list is a notice, not an error.
reset
echo '[]' > "$tmp/empty.json"
out="$("$SCRIPT" "$tmp/empty.json" 2>&1)" || note_failure "empty list: exited non-zero"
grep -q '^::notice::nothing to pin' <<<"$out" || note_failure "no notice on an empty list"
[ ! -s "$STUB_LOG" ] || note_failure "nix-store called for an empty list"

# 5. Off master (a PR ref, another branch, or unset): a notice, exit 0, and
#    nothing fetched or pushed, whatever the calling job's `if` says.
for ref in refs/pull/1/merge refs/heads/feature ""; do
  reset
  out="$(GITHUB_REF="$ref" STUB_AVAILABLE="$s/a-test-sqlite-1"$'\n'"$s/b-deps" \
    "$SCRIPT" "$tmp/all.json" 2>&1)" || note_failure "ref '$ref': exited non-zero"
  grep -q '^::notice::pins skipped' <<<"$out" || note_failure "ref '$ref': no notice"
  [ ! -s "$STUB_LOG" ] || note_failure "ref '$ref': nix-store called"
  [ ! -s "$PUSH_LOG" ] || note_failure "ref '$ref': pushed $(cat "$PUSH_LOG")"
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ci-nix-pin-test.sh: ok"
