#!/usr/bin/env bash
# Phase 3: carry each open PR to merge.
#
# The polling itself costs no tokens: `gh pr view` tells us whether checks are
# green and whether anyone has commented. An agent is only woken when there is
# something for it to do, and it is woken by resuming the very session that
# wrote the fix, so it still has the whole change in context.
#
# Usage: babysit.sh [--once]

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq claude

ONCE=0
[[ ${1:-} == --once ]] && ONCE=1
POLL="${ISSUE_LOOP_PR_POLL_SECONDS:-120}"

wake() {
  local issue=$1 reason=$2
  local uuid rounds resultf promptf
  uuid=$(state_get "$issue" .uuid)
  rounds=$(( $(state_get "$issue" .rounds || echo 0) + 1 ))
  resultf="$STATE_DIR/results/$issue.json"
  promptf="$STATE_DIR/logs/babysit-$issue-$rounds.md"

  if (( rounds > MAX_ROUNDS )); then
    state_merge "$issue" '{"phase":"needs_human","note":"exceeded max babysit rounds"}'
    warn "#$issue -> gave up after $MAX_ROUNDS rounds"
    return
  fi

  {
    cat "$SKILL_DIR/prompts/babysit.md"
    printf '\n---\n\n## This round\n\n%s\n\n' "$reason"
    printf -- '- Result file: `%s`\n' "$resultf"
    printf -- '- Round %s of %s\n\n' "$rounds" "$MAX_ROUNDS"
  } >"$promptf"

  log "#$issue -> waking agent, round $rounds ($reason)"
  claude --bg --resume "$uuid" \
    "${NO_MCP[@]}" \
    --permission-mode acceptEdits \
    --permission-prompts none \
    --max-budget-usd "$FIX_BUDGET" \
    -p "$(cat "$promptf")" \
    >"$STATE_DIR/logs/babysit-$issue-$rounds.log" 2>&1 ||
    warn "#$issue: could not resume session $uuid"

  state_merge "$issue" "$(jq -n --argjson r "$rounds" '{rounds: $r, phase: "babysitting"}')"
}

check_one() {
  local issue=$1 pr view state checks failed pending seen latest
  pr=$(state_get "$issue" .pr)
  [[ -n $pr ]] || { state_merge "$issue" '{"phase":"needs_human","note":"no PR recorded"}'; return; }

  # An agent woken last round may still be working. Leave it alone until it goes
  # idle, then read what it decided and put the issue back in the polling pool.
  if [[ $(state_get "$issue" .phase) == babysitting ]]; then
    local agent status resultf
    agent=$(state_get "$issue" .agent)
    status=$(claude agents --json 2>/dev/null |
      jq -r --arg a "$agent" '.[] | select(.id == $a) | .status // empty')
    [[ $status == busy ]] && return

    resultf="$STATE_DIR/results/$issue.json"
    if [[ -f $resultf ]] && [[ $(jq -r '.outcome // ""' <"$resultf" 2>/dev/null) == needs_human ]]; then
      state_merge "$issue" "$(jq -c '{phase: "needs_human", note: (.reason // "agent asked for a human")}' <"$resultf")"
      warn "#$issue -> agent handed back: $(jq -r '.reason // ""' <"$resultf")"
      return
    fi
    state_merge "$issue" '{"phase":"pr_open"}'
  fi

  view=$(gh pr view "$pr" --repo "$REPO" \
    --json state,mergeStateStatus,statusCheckRollup,comments,reviews 2>/dev/null) || {
    warn "#$issue: cannot read PR #$pr"; return
  }

  state=$(jq -r .state <<<"$view")
  if [[ $state == MERGED ]]; then
    state_merge "$issue" '{"phase":"merged"}'
    log "#$issue -> PR #$pr merged"
    local agent; agent=$(state_get "$issue" .agent)
    [[ -n $agent ]] && claude stop "$agent" >/dev/null 2>&1 || true
    return
  fi
  if [[ $state == CLOSED ]]; then
    state_merge "$issue" '{"phase":"needs_human","note":"PR was closed without merging"}'
    return
  fi

  checks=$(jq -r '[.statusCheckRollup[]? | .conclusion // .state // empty]' <<<"$view")
  failed=$(jq -r '[.[] | select(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ERROR")] | length' <<<"$checks")
  pending=$(jq -r '[.[] | select(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == null)] | length' <<<"$checks")

  # Newest human or bot comment we have not reacted to yet.
  latest=$(jq -r '[.comments[]?, (.reviews[]? | select((.body // "") != ""))] | map(.createdAt // .submittedAt) | max // ""' <<<"$view")
  seen=$(state_get "$issue" .last_comment_at)

  if (( failed > 0 )); then
    wake "$issue" "CI is red on PR #$pr. $failed failing check(s)."
  elif [[ -n $latest && $latest != "$seen" ]]; then
    state_merge "$issue" "$(jq -n --arg t "$latest" '{last_comment_at: $t}')"
    wake "$issue" "New review activity on PR #$pr since the last round."
  elif (( pending > 0 )); then
    log "#$issue -> PR #$pr: $pending check(s) still running"
  else
    log "#$issue -> PR #$pr green, waiting on auto-merge"
  fi
}

# Turn on auto-merge once per PR, so a green PR lands without another wake-up.
for issue in $(issues_in_phase pr_open); do
  pr=$(state_get "$issue" .pr)
  if [[ -n $pr && $(state_get "$issue" .automerge) != "true" ]]; then
    if gh pr merge "$pr" --repo "$REPO" --auto --merge >/dev/null 2>&1; then
      state_merge "$issue" '{"automerge": true}'
      log "#$issue -> auto-merge enabled on PR #$pr"
    else
      warn "#$issue -> could not enable auto-merge on PR #$pr"
    fi
  fi
done

while :; do
  mapfile -t OPEN < <(issues_in_phase pr_open babysitting)
  (( ${#OPEN[@]} )) || { log "no PRs left to babysit"; break; }

  for issue in "${OPEN[@]}"; do check_one "$issue"; done

  (( ONCE )) && break
  mapfile -t STILL < <(issues_in_phase pr_open babysitting)
  (( ${#STILL[@]} )) || break
  sleep "$POLL"
done

"$SKILL_DIR/scripts/status.sh"
