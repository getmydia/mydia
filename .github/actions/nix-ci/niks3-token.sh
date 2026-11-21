#!/usr/bin/env bash
# niks3 --auth-token-script: print {"token": "..."} (and nothing else) on stdout.
# Exec'd directly, so it needs a shebang and the executable bit. The audience
# must match the niks3 server's GitHub OIDC provider and is URL-encoded because
# it is a query parameter. Needs the job to have `id-token: write`.
#
# Exits non-zero, with a message on stderr, when the OIDC response carries no
# token, so niks3 reports an auth failure instead of sending {"token": null}.
set -euo pipefail
response="$(curl -fsSL \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=https%3A%2F%2Fniks3.mydia.dev")"
if ! jq -ce 'select((.value // "") != "") | {token: .value}' <<<"$response"; then
  echo "niks3-token.sh: the OIDC response carried no token" >&2
  exit 1
fi
