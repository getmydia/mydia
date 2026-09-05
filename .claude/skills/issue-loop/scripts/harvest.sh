#!/usr/bin/env bash
# Waits for phase-2 agents to finish and records what each one did.
#
# An agent is done when it writes its result file. An agent that has gone idle
# without writing one is stuck: it hit its budget, ran out of turns, or talked
# itself into a corner. Those are marked needs_human rather than waited on
# forever.
#
# Usage: harvest.sh [--once]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq claude

ONCE=0
[[ ${1:-} == --once ]] && ONCE=1

POLL="${ISSUE_LOOP_POLL_SECONDS:-30}"
IDLE_GRACE="${ISSUE_LOOP_IDLE_GRACE:-3}"   # consecutive idle polls before giving up

harvest_one() {
  local issue=$1
  local resultf="$STATE_DIR/results/$issue.json"
  local agent outcome status idle

  agent=$(state_get "$issue" .agent)

  if [[ -f $resultf ]] && jq -e .outcome >/dev/null 2>&1 <"$resultf"; then
    outcome=$(jq -r .outcome <"$resultf")
    case $outcome in
      pr_opened)
        state_merge "$issue" "$(jq -c '{phase: "pr_open", pr: .pr, branch: (.branch // ""), note: (.note // "")}' <"$resultf")"
        log "#$issue -> PR #$(jq -r .pr <"$resultf")"
        ;;
      bailout)
        state_merge "$issue" "$(jq -c '{phase: "skipped", note: ("bailout: " + (.reason // "no reason given"))}' <"$resultf")"
        log "#$issue -> bailed out: $(jq -r '.reason // ""' <"$resultf")"
        ;;
      *)
        state_merge "$issue" "$(jq -c '{phase: "failed", note: (.reason // "agent reported failure")}' <"$resultf")"
        warn "#$issue -> failed: $(jq -r '.reason // ""' <"$resultf")"
        ;;
    esac
    [[ -n $agent ]] && claude stop "$agent" >/dev/null 2>&1 || true
    return
  fi

  # No result file yet. Is the agent still alive and working?
  status=$(claude agents --json 2>/dev/null |
    jq -r --arg a "$agent" '.[] | select(.id == $a) | .status // empty')

  if [[ -z $status ]]; then
    state_merge "$issue" '{"phase":"needs_human","note":"agent exited without writing a result file"}'
    warn "#$issue -> agent gone, no result"
    return
  fi

  if [[ $status == idle ]]; then
    idle=$(( $(state_get "$issue" .idle_polls || echo 0) + 1 ))
    state_merge "$issue" "$(jq -n --argjson i "$idle" '{idle_polls: $i}')"
    if (( idle >= IDLE_GRACE )); then
      state_merge "$issue" '{"phase":"needs_human","note":"agent went idle without writing a result file"}'
      warn "#$issue -> stuck and idle, marked needs_human (claude attach $agent to take over)"
      claude stop "$agent" >/dev/null 2>&1 || true
    fi
  else
    state_merge "$issue" '{"idle_polls": 0}'
  fi
}

while :; do
  mapfile -t PENDING < <(issues_in_phase fixing)
  (( ${#PENDING[@]} )) || { log "no agents still fixing"; break; }

  for issue in "${PENDING[@]}"; do harvest_one "$issue"; done

  mapfile -t STILL < <(issues_in_phase fixing)
  (( ${#STILL[@]} )) || break
  (( ONCE )) && break

  log "${#STILL[@]} still working: ${STILL[*]}"
  sleep "$POLL"
done

"$SKILL_DIR/scripts/status.sh"
