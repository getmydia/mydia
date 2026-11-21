#!/usr/bin/env bash
# pre-push hook: build the pushed commit's CI outputs in the background and
# push them to the CI binary cache (scripts/nix-cache-push.sh).
#
# Never blocks or fails a push. Silent no-op without a niks3 token, so it
# only does anything on a maintainer machine. MYDIA_NIX_PUSH=builds (default),
# all, or off. Pushes queue behind a lock instead of building concurrently.
set -uo pipefail

mode="${MYDIA_NIX_PUSH:-builds}"
token="${NIKS3_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mydia/niks3-token}"
[ "$mode" = off ] && exit 0
[ -r "$token" ] || exit 0

# prek exports the pushed commit as PRE_COMMIT_TO_REF. Deleting a branch
# pushes the all-zero object id: nothing to build.
rev="${PRE_COMMIT_TO_REF:-}"
case "$rev" in "" | *[!0]*) ;; *) exit 0 ;; esac
[ -n "$rev" ] || exit 0

root=$(git rev-parse --show-toplevel)
state="${DEVENV_STATE:-$root/.devenv/state}"
mkdir -p "$state"
log="$state/nix-cache-push.log"

setsid nohup flock "$state/nix-cache-push.lock" \
  "$root/scripts/nix-cache-push.sh" --rev "$rev" --mode "$mode" \
  >>"$log" 2>&1 </dev/null &

echo "nix-cache-push: building ${rev:0:9} ($mode) in the background, log: $log"
exit 0
