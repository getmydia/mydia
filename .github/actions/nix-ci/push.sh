#!/usr/bin/env bash
# Push store paths to the CI binary cache (niks3) with a GitHub OIDC token.
#
# Usage: push.sh <out-paths...>
# Env:   NIKS3_PIN           optional pin name (the action sets it on master only)
#        NIKS3_URL           server, default https://niks3.mydia.dev
#        NIKS3_RETRY_DELAY   base seconds between attempts, default 15
#        NIKS3_PUSH_TIMEOUT  seconds one attempt may take, default 600
#
# A cache push is an optimisation, so this never fails the job: after 3
# attempts (a missing niks3 or a timed-out attempt counts as a failure) it
# warns and exits 0.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]; then
  echo "::notice::niks3 push skipped: no OIDC token (fork PR, or job lacks id-token: write)"
  exit 0
fi

if [ "$#" -eq 0 ]; then
  echo "::notice::niks3 push skipped: no store paths given"
  exit 0
fi

args=(--server-url "${NIKS3_URL:-https://niks3.mydia.dev}" --auth-token-script "$here/niks3-token.sh")
if [ -n "${NIKS3_PIN:-}" ]; then
  args+=(--pin "$NIKS3_PIN")
fi

delay="${NIKS3_RETRY_DELAY:-15}"
limit="${NIKS3_PUSH_TIMEOUT:-600}"
for attempt in 1 2 3; do
  if timeout "$limit" niks3 push "${args[@]}" "$@"; then
    exit 0
  fi
  echo "niks3 push attempt $attempt failed"
  if [ "$attempt" -lt 3 ]; then
    sleep $((attempt * delay))
  fi
done

echo "::warning::niks3 push failed after 3 attempts; the cache will miss next run"
exit 0
