#!/bin/bash
# Runs the player integration tests against an already-running E2E stack, on
# the client VM of the player-e2e NixOS test (nix/tests/player-e2e.nix). The
# working directory is a copy of player-codegen, so dependencies are resolved
# and code is generated already; the VM has no network for `pub get`.
set -euo pipefail

TEST_TARGET="${E2E_TEST_TARGET:-integration_test/all_tests.dart}"

# The fewest tests of the `playback` group (integration_test/playback_test.dart)
# that must pass. A skipped test, or one that returns before asserting, still
# leaves `flutter test` at exit 0, so this count is what notices the group
# quietly testing less. Adding a playback test means raising it; removing one
# means lowering it in the same change.
PLAYBACK_MIN_PASSED=7

# Counts the passed tests in the run's JSON report. nix/tests/player-e2e.nix
# passes its store path; from a checkout it sits in scripts/ci.
ASSERT_TEST_COUNT="${ASSERT_TEST_COUNT:-$(dirname "${BASH_SOURCE[0]}")/../ci/assert-test-count.sh}"

echo "============================================"
echo "Flutter E2E Integration Test Runner"
echo "============================================"
echo "  MYDIA_URL:       ${MYDIA_URL:-not set}"
echo "  RELAY_URL:       ${RELAY_URL:-not set}"
echo "  E2E_TEST_TARGET: ${TEST_TARGET}"
echo ""

wait_for() {
    name="$1"
    url="$2"
    attempt=0
    while [ "$attempt" -lt 30 ]; do
        if curl -sf "${url}/health" >/dev/null 2>&1; then
            echo "  ${name} is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    echo "ERROR: ${name} not available at ${url}" >&2
    return 1
}

wait_for "Mydia" "${MYDIA_URL}"
wait_for "Relay" "${RELAY_URL}"

if [ ! -f "$TEST_TARGET" ]; then
    echo "ERROR: test target not found: $TEST_TARGET" >&2
    exit 1
fi

# Started in the background below, where a missing binary would only show as
# a fullscreen test that times out, so check for it up front.
if ! command -v openbox >/dev/null 2>&1; then
    echo "ERROR: openbox is not on PATH; the playback tests need it as the Xvfb window manager" >&2
    exit 1
fi

# Checked up front for the same reason: it runs only after the whole suite.
if [ ! -f "$ASSERT_TEST_COUNT" ]; then
    echo "ERROR: test count guard not found at $ASSERT_TEST_COUNT" >&2
    exit 1
fi

# The clips integration_test/playback_test.dart plays, written fresh each run:
# the VM has no network to fetch fixtures from. The subtitle clip is the same
# video with one English SRT cue over its whole length.
CLIPS_DIR=$(mktemp -d)
echo "Generating playback clips in ${CLIPS_DIR}..."
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=duration=10:size=1280x720:rate=24 \
    -f lavfi -i sine=frequency=440:duration=10 \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -shortest \
    "${CLIPS_DIR}/e2e_sdr.mp4"
printf '1\n00:00:00,000 --> 00:00:10,000\nMydia playback subtitle check\n' \
    > "${CLIPS_DIR}/e2e_subs.srt"
ffmpeg -hide_banner -loglevel error -y \
    -i "${CLIPS_DIR}/e2e_sdr.mp4" -i "${CLIPS_DIR}/e2e_subs.srt" \
    -map 0:v -map 0:a -map 1:s -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng \
    "${CLIPS_DIR}/e2e_subs.mkv"

# The dart-defines every build below shares. The claim code is added only to
# `flutter test`'s.
dart_defines=(
    "--dart-define=MYDIA_URL=${MYDIA_URL}"
    "--dart-define=RELAY_URL=${RELAY_URL}"
    --dart-define=E2E_MODE=true
    "--dart-define=MYDIA_E2E_CLIPS=${CLIPS_DIR}"
)

# Build the Linux debug app for the test target before minting the claim
# code. The code is single-use and expires 300 s after it is minted, and a
# cold build (CMake, the native plugins, the Dart kernel) is most of that on
# a slow runner. `flutter test -d linux` then only recompiles the kernel for
# the extra define.
echo "Pre-building the Linux debug app..."
flutter build linux --debug --target "$TEST_TARGET" "${dart_defines[@]}"

echo "Logging in as test admin..."
LOGIN_RESPONSE=$(curl -sf "${MYDIA_URL}/api/graphql" \
    -H "Content-Type: application/json" \
    -d '{
        "query": "mutation Login($input: LoginInput!) { login(input: $input) { token } }",
        "variables": {
            "input": {
                "username": "'"${E2E_ADMIN_EMAIL:-admin@test.local}"'",
                "password": "'"${E2E_ADMIN_PASSWORD:-testpassword123}"'",
                "deviceId": "e2e-test-runner",
                "deviceName": "E2E Test Runner",
                "platform": "linux"
            }
        }
    }' 2>&1) || true

AUTH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.data.login.token // empty' 2>/dev/null || true)
if [ -z "$AUTH_TOKEN" ]; then
    echo "ERROR: failed to login to Mydia" >&2
    echo "Response: $LOGIN_RESPONSE" >&2
    exit 1
fi
echo "  Login successful"

echo "Generating claim code..."
CLAIM_CODE=""
claim_attempt=0
while [ "$claim_attempt" -lt 30 ]; do
    CLAIM_RESPONSE=$(curl -sf "${MYDIA_URL}/api/graphql" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"query": "mutation { generateClaimCode { code expiresAt } }"}' 2>&1) || true

    CLAIM_CODE=$(echo "$CLAIM_RESPONSE" | jq -r '.data.generateClaimCode.code // empty' 2>/dev/null || true)
    [ -n "$CLAIM_CODE" ] && break

    claim_attempt=$((claim_attempt + 1))
    claim_error=$(echo "$CLAIM_RESPONSE" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null || true)
    echo "  Claim code attempt ${claim_attempt}/30 failed: ${claim_error:-empty or unparseable response}"
    sleep 2
done

if [ -z "$CLAIM_CODE" ]; then
    echo "ERROR: failed to generate claim code" >&2
    exit 1
fi
echo "  Claim code generated: $CLAIM_CODE"

REPORT_DIR=$(mktemp -d)
REPORT_FILE="${REPORT_DIR}/e2e-report.json"

flutter_cmd=(
    flutter test "$TEST_TARGET"
    -d linux
    --concurrency=1
    --reporter expanded
    --file-reporter "json:${REPORT_FILE}"
    "${dart_defines[@]}"
    "--dart-define=E2E_CLAIM_CODE=${CLAIM_CODE}"
)

test_exit=0
# openbox gives the bare Xvfb display a window manager: without one GTK's
# fullscreen request goes unanswered and the window never reports it, which
# playback_test.dart's fullscreen test needs. A window manager also keeps
# the window inside the screen, and xvfb-run's default screen is 640x480,
# which would push the login screen's Connect button out of the window: the
# screen is sized for a desktop instead.
#
# Every wait inside the suite has a deadline, but those are Dart timers, and a
# frozen GTK thread stops them along with the rest of the app (the media_kit
# software redraw that once locked a freed mutex did exactly that). So the run
# itself gets one: past it, the app's native stacks are printed and the app is
# killed, which fails the run with something to read instead of a silent
# timeout of the whole VM test. The suite takes a few minutes; this leaves the
# VM test's own limit room for the app build before it.
suite_limit=600
(
    waited=0
    while [ "$waited" -lt "$suite_limit" ]; do
        sleep 5 </dev/null >/dev/null 2>&1
        waited=$((waited + 5))
    done
    echo "ERROR: flutter test still running after ${suite_limit}s; native stacks of the app:" >&2
    for pid in $(pgrep -f 'bundle/mydia-player' || true); do
        timeout 90 gdb -p "$pid" -batch -ex "thread apply all bt 40" 2>&1 \
            | grep -v '^\[New LWP' >&2 || true
    done
    pkill -KILL -f 'bundle/mydia-player' || true
) &
watchdog=$!
xvfb-run -a -s "-screen 0 1920x1080x24" \
    sh -c 'openbox & exec "$@"' sh "${flutter_cmd[@]}" || test_exit=$?
kill "$watchdog" 2>/dev/null || true

echo ""
echo "Skipped tests across all of integration_test/ (static grep, not scoped to E2E_TEST_TARGET; see each skip reason):"
grep -rn "skip:" integration_test/ || echo "  none"

echo ""
# Only all_tests.dart puts the `playback` group in front of the names, and
# only the full suite should hold the pinned count. nix/tests/player-e2e.nix
# pins that target, so CI always runs the guard.
count_exit=0
if [ "$TEST_TARGET" = "integration_test/all_tests.dart" ]; then
    echo "Passed playback tests (minimum ${PLAYBACK_MIN_PASSED}):"
    bash "$ASSERT_TEST_COUNT" "$REPORT_FILE" "$PLAYBACK_MIN_PASSED" "playback " || count_exit=$?
else
    echo "Playback test count guard skipped: it runs only for integration_test/all_tests.dart, not ${TEST_TARGET}"
fi

if [ "$test_exit" -ne 0 ]; then
    exit "$test_exit"
fi
exit "$count_exit"
