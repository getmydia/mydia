#!/bin/sh
# E2E wrapper around the stock production entrypoint.
#
# Backgrounds a "wait for healthy, then seed" step and then execs the real
# entrypoint in the foreground, so PID 1 semantics and the production startup
# path (PUID handling, migrations) are exactly what ships. The former
# Dockerfile.e2e entrypoint reimplemented migrations itself; this does not.
set -eu

(
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if curl -sf "http://localhost:${PORT:-4000}/health" >/dev/null 2>&1; then
            echo "E2E: server healthy, seeding"
            if sh /e2e/seed.sh; then
                echo "E2E: seeding succeeded"
            else
                echo "E2E: SEEDING FAILED, tests will not have their fixtures" >&2
            fi
            exit 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    echo "E2E: server never became healthy, skipping seed" >&2
) &

exec /docker-entrypoint.sh /app/bin/mydia start
