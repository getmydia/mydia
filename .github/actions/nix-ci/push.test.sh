#!/usr/bin/env bash
# Contract test for push.sh: no network, niks3 is a stub on PATH.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir "$tmp/bin"
cat > "$tmp/bin/niks3" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
exit "${STUB_EXIT:-1}"
STUB
chmod +x "$tmp/bin/niks3"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/calls" NIKS3_RETRY_DELAY=0
: > "$STUB_LOG"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. No OIDC environment: notice, exit 0, niks3 never called.
out="$(env -u ACTIONS_ID_TOKEN_REQUEST_URL bash "$here/push.sh" /nix/store/x 2>&1)" || fail "unset OIDC exited non-zero"
grep -q '^::notice::' <<<"$out" || fail "no notice when OIDC unset"
[ ! -s "$STUB_LOG" ] || fail "niks3 called without OIDC"

# 2. OIDC set, niks3 always fails: 3 attempts, one warning, exit 0.
out="$(ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' NIKS3_URL=https://niks3.invalid \
  bash "$here/push.sh" /nix/store/x 2>&1)" || fail "failing push exited non-zero"
[ "$(wc -l < "$STUB_LOG")" -eq 3 ] || fail "expected 3 attempts, got $(wc -l < "$STUB_LOG")"
[ "$(grep -c '^::warning::' <<<"$out")" -eq 1 ] || fail "expected exactly one warning"
grep -q -- '--server-url https://niks3.invalid' "$STUB_LOG" || fail "server url not passed"
grep -q -- '--auth-token-script' "$STUB_LOG" || fail "token script not passed"
if grep -q -- '--pin' "$STUB_LOG"; then fail "pin passed without PIN"; fi

# 3. Success on first attempt with a pin: one call, no warning.
: > "$STUB_LOG"
out="$(STUB_EXIT=0 PIN=master-x ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' \
  bash "$here/push.sh" /nix/store/x 2>&1)" || fail "successful push exited non-zero"
[ "$(wc -l < "$STUB_LOG")" -eq 1 ] || fail "expected 1 attempt on success"
grep -q -- '--pin master-x' "$STUB_LOG" || fail "pin not passed"
if grep -q '^::warning::' <<<"$out"; then fail "warning on success"; fi

echo "push.test.sh: ok"
