#!/usr/bin/env bash
# Phase 2: fix the approved issues, one background agent per issue.
#
# Each agent gets its own git worktree (courtesy of `claude --bg -w`) and its own
# pre-generated session UUID, so phase 3 can resume exactly the session that
# wrote the fix, with its context intact.
#
# Usage: fix.sh [--yolo] [issue...]
#   --yolo      also run issues triage marked 'skipped' (you asked for it)
#   issue...    fix only these numbers instead of every approved issue

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq claude uuidgen

YOLO=0
EXPLICIT=()
for arg in "$@"; do
  case $arg in
    --yolo) YOLO=1 ;;
    [0-9]*) EXPLICIT+=("$arg") ;;
    *)      die "unknown argument: $arg" ;;
  esac
done

if (( ${#EXPLICIT[@]} )); then
  TARGETS=("${EXPLICIT[@]}")
elif (( YOLO )); then
  mapfile -t TARGETS < <(issues_in_phase approved skipped)
else
  mapfile -t TARGETS < <(issues_in_phase approved)
fi

(( ${#TARGETS[@]} )) || { log "nothing approved to fix; run triage.sh first"; exit 0; }
log "${#TARGETS[@]} issue(s) to fix, ${FIX_CONCURRENCY} at a time"

AGENT_NAME_PREFIX="issue-loop"
mkdir -p "$STATE_DIR/results"

# running_count -- how many of OUR agents are still alive. Matching on the name
# prefix rather than cwd keeps us from counting the user's own sessions.
running_count() {
  claude agents --json 2>/dev/null |
    jq --arg p "$AGENT_NAME_PREFIX" '[.[] | select(.name // "" | startswith($p))] | length'
}

launch() {
  local issue=$1
  local uuid short branch wt promptf resultf title verdict
  uuid=$(uuidgen)
  short=${uuid:0:8}
  branch="fix/issue-$issue"
  wt="$MAIN_ROOT/.claude/worktrees/issue-$issue"
  resultf="$STATE_DIR/results/$issue.json"
  promptf="$STATE_DIR/logs/prompt-$issue.md"
  rm -f "$resultf"

  title=$(state_get "$issue" .title)
  verdict=$(state_get "$issue" '.verdict | tojson')

  {
    cat "$SKILL_DIR/prompts/fix.md"
    printf '\n---\n\n## Task data\n\n'
    printf -- '- Issue: **#%s** in `%s`\n' "$issue" "$REPO"
    printf -- '- Title: %s\n' "$title"
    printf -- '- Rename your branch to `%s` as your very first action: `git branch -m %s`\n' "$branch" "$branch"
    printf -- '- Write your result file to exactly this path: `%s`\n' "$resultf"
    printf '\n### Triage findings\n\n```json\n%s\n```\n' "$verdict"
    printf '\n### Issue body\n\n'
    gh issue view "$issue" --repo "$REPO" --json body -q .body
    printf '\n### Comments\n\n'
    gh issue view "$issue" --repo "$REPO" --json comments \
      -q '.comments[] | "**\(.author.login):** \(.body)\n"' 2>/dev/null || true
  } >"$promptf"

  claude --bg \
    -w "issue-$issue" \
    -n "$AGENT_NAME_PREFIX #$issue" \
    --session-id "$uuid" \
    --model "$MODEL" \
    "${NO_MCP[@]}" \
    --permission-mode acceptEdits \
    --permission-prompts none \
    --max-budget-usd "$FIX_BUDGET" \
    --append-system-prompt "$(cat "$SKILL_DIR/prompts/guardrails.md")" \
    -p "$(cat "$promptf")" \
    >"$STATE_DIR/logs/launch-$issue.log" 2>&1 ||
    { warn "#$issue: launch failed, see $STATE_DIR/logs/launch-$issue.log"; return 1; }

  state_merge "$issue" "$(jq -n \
    --arg u "$uuid" --arg s "$short" --arg b "$branch" --arg w "$wt" \
    '{phase: "fixing", uuid: $u, agent: $s, branch: $b, worktree: $w, idle_polls: 0}')"
  log "#$issue launched as agent $short in $wt"
}

for issue in "${TARGETS[@]}"; do
  while (( $(running_count) >= FIX_CONCURRENCY )); do sleep 20; done
  launch "$issue" || state_merge "$issue" '{"phase":"failed","note":"agent launch failed"}'
  sleep 2   # stagger, so N worktree creations do not all compile at once
done

log "all agents launched; harvesting"
exec "$SKILL_DIR/scripts/harvest.sh"
