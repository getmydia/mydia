#!/usr/bin/env bash
# Kill switch. Stops every agent this loop started, leaving their conversations
# intact so you can `claude attach <id>` and take over any of them by hand.
#
# Usage: stop-all.sh [--rm]
#   --rm   also delete the sessions and their worktrees, where that is safe

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RM=0
[[ ${1:-} == --rm ]] && RM=1

mapfile -t AGENTS < <(claude agents --json 2>/dev/null |
  jq -r '.[] | select(.name // "" | startswith("issue-loop")) | .id')

(( ${#AGENTS[@]} )) || { log "no issue-loop agents running"; exit 0; }

for a in "${AGENTS[@]}"; do
  log "stopping $a"
  claude stop "$a" >/dev/null 2>&1 || warn "could not stop $a"
  if (( RM )); then
    claude rm "$a" >/dev/null 2>&1 || warn "could not remove $a"
  fi
done

log "stopped ${#AGENTS[@]} agent(s)"
(( RM )) || log "conversations kept; 'claude attach <id>' to take one over"
