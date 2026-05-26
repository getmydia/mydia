#!/bin/bash
set -e

# Install deps if node_modules is missing or stale (pnpm-lock.yaml newer).
if [ ! -d "node_modules" ] || [ "pnpm-lock.yaml" -nt "node_modules" ]; then
    echo "[rs-frontend] pnpm install..."
    pnpm install --frozen-lockfile
fi

exec "$@"
