#!/bin/sh
# E2E wrapper around the stock production entrypoint.
#
# Backgrounds a "wait for healthy, then seed" step and then execs the real
# entrypoint in the foreground, so PID 1 semantics and the production startup
# path (PUID handling, migrations) are exactly what ships. The former
# Dockerfile.e2e entrypoint reimplemented migrations itself; this does not.
#
# A sentinel file marks seeding success. Written only when seed.sh returns 0,
# never on failure. compose's healthcheck requires both the HTTP health
# endpoint and this file, so a seeding failure keeps the container unhealthy
# instead of letting dependents start against fixtures that were never
# created.
set -eu

# /tmp is the container's ordinary writable layer, not a tmpfs mount, and the
# mydia service has no restart policy, so a stopped-then-started container
# (compose reusing it rather than recreating it, e.g. after a Ctrl-C that
# skipped the trailing `down -v`) keeps whatever this file held last time.
# Clear it before the health poll can even start, so its presence can only
# ever mean "seeding succeeded during this run."
rm -f /tmp/e2e-seeded

(
    attempt=0
    while [ "$attempt" -lt 60 ]; do
        if curl -sf "http://localhost:${PORT:-4000}/health" >/dev/null 2>&1; then
            echo "E2E: server healthy, seeding"
            if sh /e2e/seed.sh; then
                echo "E2E: seeding succeeded"
                touch /tmp/e2e-seeded
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
