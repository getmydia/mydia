#!/usr/bin/env bash
# Contract test for push.sh and niks3-token.sh: no network, niks3 and curl
# are stubs on PATH.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A PATH holding only what push.sh needs besides niks3, for case 4.
mkdir "$tmp/min"
for tool in bash dirname sleep timeout; do
  ln -s "$(command -v "$tool")" "$tmp/min/$tool"
done

mkdir "$tmp/bin"
cat > "$tmp/bin/niks3" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
exit "${STUB_EXIT:-1}"
STUB
chmod +x "$tmp/bin/niks3"
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$CURL_BODY"
STUB
chmod +x "$tmp/bin/curl"
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
if grep -q -- '--pin' "$STUB_LOG"; then fail "pin passed without NIKS3_PIN"; fi

# 3. Success on first attempt with a pin: one call, no warning.
: > "$STUB_LOG"
out="$(STUB_EXIT=0 NIKS3_PIN=master-x ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' \
  bash "$here/push.sh" /nix/store/x 2>&1)" || fail "successful push exited non-zero"
[ "$(wc -l < "$STUB_LOG")" -eq 1 ] || fail "expected 1 attempt on success"
grep -q -- '--pin master-x' "$STUB_LOG" || fail "pin not passed"
if grep -q '^::warning::' <<<"$out"; then fail "warning on success"; fi

# 4. niks3 missing from PATH: 3 failed attempts, one warning, exit 0.
out="$(PATH="$tmp/min" ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' \
  "$tmp/min/bash" "$here/push.sh" /nix/store/x 2>&1)" || fail "push without niks3 exited non-zero"
[ "$(grep -c '^niks3 push attempt [0-9] failed$' <<<"$out")" -eq 3 ] \
  || fail "expected 3 failed attempts without niks3"
[ "$(grep -c '^::warning::' <<<"$out")" -eq 1 ] || fail "expected one warning without niks3"

# 5. An attempt that outlives NIKS3_PUSH_TIMEOUT is killed and counts as a failure.
: > "$STUB_LOG"
out="$(STUB_EXIT=0 STUB_SLEEP=30 NIKS3_PUSH_TIMEOUT=1 ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' \
  bash "$here/push.sh" /nix/store/x 2>&1)" || fail "timed-out push exited non-zero"
[ "$(wc -l < "$STUB_LOG")" -eq 3 ] || fail "expected 3 attempts when each times out"
[ "$(grep -c '^::warning::' <<<"$out")" -eq 1 ] || fail "expected one warning on timeouts"

# 6. niks3-token.sh: a token is wrapped as {"token": ...}; a response without
#    one fails with a message instead of printing {"token": null}.
export ACTIONS_ID_TOKEN_REQUEST_URL='https://oidc.invalid/t?x=1' ACTIONS_ID_TOKEN_REQUEST_TOKEN=req
out="$(CURL_BODY='{"value":"abc"}' bash "$here/niks3-token.sh")" || fail "token script failed on a token"
[ "$out" = '{"token":"abc"}' ] || fail "unexpected token output: $out"
for body in '{}' '{"value":null}' '{"value":""}' 'not json'; do
  if out="$(CURL_BODY="$body" bash "$here/niks3-token.sh" 2>&1)"; then
    fail "token script succeeded on $body"
  fi
  grep -q 'carried no token' <<<"$out" || fail "no message for $body"
  if grep -q '"token"' <<<"$out"; then fail "token JSON printed for $body"; fi
done

echo "push.test.sh: ok"
