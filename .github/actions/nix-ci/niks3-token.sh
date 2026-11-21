#!/usr/bin/env bash
# niks3 --auth-token-script: print {"token": "..."} (and nothing else) on stdout.
# Exec'd directly, so it needs a shebang and the executable bit. The audience
# must match the niks3 server's GitHub OIDC provider and is URL-encoded because
# it is a query parameter. Needs the job to have `id-token: write`.
set -euo pipefail
curl -fsSL \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fniks3.mydia.dev" \
  | jq -c '{token: .value}'
