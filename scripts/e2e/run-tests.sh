#!/bin/bash
# Runs the player integration tests against an already-running E2E stack.
#
# Mounted into the toolbox image rather than baked in, so editing it does not
# invalidate an image layer.
set -euo pipefail

TEST_TARGET="${E2E_TEST_TARGET:-integration_test/all_tests.dart}"

echo "============================================"
echo "Flutter E2E Integration Test Runner"
echo "============================================"
echo "  MYDIA_URL:       ${MYDIA_URL:-not set}"
echo "  RELAY_URL:       ${RELAY_URL:-not set}"
echo "  E2E_TEST_TARGET: ${TEST_TARGET}"
echo "  E2E_TEST_ARGS:   ${E2E_TEST_ARGS:-<none>}"
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

echo "Resolving Flutter dependencies..."
flutter pub get >/tmp/flutter-pub-get.log 2>&1 || {
    echo "ERROR: flutter pub get failed" >&2
    cat /tmp/flutter-pub-get.log >&2
    exit 1
}

echo "Running code generation..."
flutter pub run build_runner build --delete-conflicting-outputs \
    >/tmp/build-runner.log 2>&1 || {
    echo "ERROR: build_runner failed" >&2
    cat /tmp/build-runner.log >&2
    exit 1
}

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

AUTH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.data.login.token // empty')
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

    CLAIM_CODE=$(echo "$CLAIM_RESPONSE" | jq -r '.data.generateClaimCode.code // empty')
    [ -n "$CLAIM_CODE" ] && break

    claim_attempt=$((claim_attempt + 1))
    echo "  Claim code attempt ${claim_attempt}/30 failed: $(echo "$CLAIM_RESPONSE" | jq -r '.errors[0].message // "unknown error"')"
    sleep 2
done

if [ -z "$CLAIM_CODE" ]; then
    echo "ERROR: failed to generate claim code" >&2
    exit 1
fi
echo "  Claim code generated: $CLAIM_CODE"

flutter_cmd=(
    flutter test "$TEST_TARGET"
    -d linux
    --concurrency=1
    --reporter expanded
    --dart-define=MYDIA_URL=${MYDIA_URL}
    --dart-define=RELAY_URL=${RELAY_URL}
    --dart-define=E2E_MODE=true
    --dart-define=E2E_CLAIM_CODE=${CLAIM_CODE}
)

if [ -n "${E2E_TEST_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    extra_args=(${E2E_TEST_ARGS})
    flutter_cmd+=("${extra_args[@]}")
fi

xvfb-run -a "${flutter_cmd[@]}"
