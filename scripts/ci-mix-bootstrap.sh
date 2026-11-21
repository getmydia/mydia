#!/usr/bin/env bash
# Installs Hex and Rebar in CI when absent from the restored archive cache,
# retrying transient builds.hex.pm fetches cleanly.
set -euo pipefail

retry_mix() {
  local task="$1"
  local attempt
  for attempt in 1 2 3; do
    if mix "$task" --force --if-missing; then
      return 0
    fi
    echo "::warning::mix $task failed (attempt $attempt/3)" >&2
    if [ "$attempt" -lt 3 ]; then
      sleep "$((attempt * 5))"
    fi
  done
  return 1
}

retry_mix local.hex
retry_mix local.rebar
