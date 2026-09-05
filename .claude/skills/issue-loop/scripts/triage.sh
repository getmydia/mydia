#!/usr/bin/env bash
# Phase 1: decide which open issues an agent should attempt.
#
# Read-only by construction. Every triage agent runs with --restricted and a
# tool list of Read,Grep,Glob, so it has no Bash and no Edit and cannot change
# anything even if it decides it wants to.
#
# Usage: triage.sh [--refresh] [issue...]
#   --refresh   re-triage issues that already have a verdict
#   issue...    triage only these numbers instead of scanning open issues

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq claude

REFRESH=0
EXPLICIT=()
for arg in "$@"; do
  case $arg in
    --refresh) REFRESH=1 ;;
    [0-9]*)    EXPLICIT+=("$arg") ;;
    *)         die "unknown argument: $arg" ;;
  esac
done

# A single shared worktree for all triage agents. They only read, so one
# checkout serves every agent and costs far less than one per issue.
TRIAGE_WT="$MAIN_ROOT/.claude/worktrees/issue-loop-triage"
if [[ -d $TRIAGE_WT ]]; then
  git -C "$TRIAGE_WT" fetch --quiet origin || true
  git -C "$TRIAGE_WT" checkout --quiet --detach "$BASE_REF"
else
  log "creating shared triage worktree at $TRIAGE_WT"
  git -C "$MAIN_ROOT" fetch --quiet origin || true
  git -C "$MAIN_ROOT" worktree add --quiet --detach "$TRIAGE_WT" "$BASE_REF"
fi

if (( ${#EXPLICIT[@]} )); then
  ISSUES=$(
    for n in "${EXPLICIT[@]}"; do
      gh issue view "$n" --repo "$REPO" --json number,title,body,labels
    done | jq -sc .
  )
else
  log "fetching open bug and crash issues from $REPO"
  ISSUES=$(gh issue list --repo "$REPO" --state open --limit 300 \
    --json number,title,body,labels |
    jq -c '[.[] | select([.labels[].name] | any(. == "bug" or . == "crash"))]')
fi

COUNT=$(jq length <<<"$ISSUES")
log "$COUNT candidate issue(s)"
(( COUNT )) || { log "nothing to triage"; exit 0; }

# triage_one <issue> <title> <body> <labels-json>
triage_one() {
  local issue=$1 title=$2 body=$3 labels=$4
  local logf="$STATE_DIR/logs/triage-$issue.log"
  local out raw gated

  out=$(
    {
      cat "$SKILL_DIR/prompts/triage.md"
      printf '\n---\n\n# Issue #%s\n\n**Title:** %s\n\n**Labels:** %s\n\n**Body:**\n\n%s\n' \
        "$issue" "$title" "$labels" "$body"
    } | (
      cd "$TRIAGE_WT" && claude -p \
        --model "$MODEL" \
        --restricted \
        --tools Read,Grep,Glob \
        "${NO_MCP[@]}" \
        --permission-prompts none \
        --output-format json \
        --json-schema "$(cat "$SKILL_DIR/schema/triage.json")" \
        --max-budget-usd "$TRIAGE_BUDGET" \
        --no-session-persistence
    ) 2>"$logf"
  ) || { warn "#$issue: triage agent failed, see $logf"; return 0; }

  raw=$(claude_result "$out")
  if ! jq -e '.verdict' >/dev/null 2>&1 <<<"$raw"; then
    warn "#$issue: unparseable verdict, see $logf"
    printf '%s\n' "$raw" >>"$logf"
    state_merge "$issue" '{"phase":"needs_human","note":"triage returned no usable verdict"}'
    return 0
  fi

  # The gate. Every clause must hold for the loop to proceed unattended.
  gated=$(jq -c \
    --argjson minc "$MIN_CONFIDENCE" \
    --argjson maxf "$MAX_FILES" \
    --argjson labels "$labels" '
      . as $v
      | ($v.verdict == "take"
         and $v.confidence >= $minc
         and $v.risk == "low"
         and ($v.files_to_change | length) <= $maxf
         and ($labels | any(. == "bug" or . == "crash"))) as $ok
      | {verdict: $v, phase: (if $ok then "approved" else "skipped" end)}
    ' <<<"$raw")

  state_merge "$issue" "$gated"
  log "#$issue -> $(jq -r .phase <<<"$gated") ($(jq -r .verdict <<<"$raw") @ $(jq -r .confidence <<<"$raw"), risk $(jq -r .risk <<<"$raw"))"
}

# Process substitution, not a pipe: a pipe would run the loop in a subshell and
# `throttle` would never see the background jobs.
while read -r row; do
  n=$(jq -r .number <<<"$row")
  title=$(jq -r .title <<<"$row")
  body=$(jq -r '.body // ""' <<<"$row")
  labels=$(jq -c '[.labels[].name]' <<<"$row")

  existing=$(state_get "$n" .phase)
  if [[ -n $existing && $existing != new && $REFRESH -eq 0 ]]; then
    log "#$n already at phase '$existing', skipping (use --refresh to redo)"
    continue
  fi

  state_merge "$n" "$(jq -n --argjson i "$n" --arg t "$title" --argjson l "$labels" \
    '{issue: $i, title: $t, labels: $l, phase: "new", rounds: 0}')"

  throttle "$TRIAGE_CONCURRENCY"
  triage_one "$n" "$title" "$body" "$labels" &
done < <(jq -c '.[]' <<<"$ISSUES")
wait

log "triage complete"
"$SKILL_DIR/scripts/status.sh"
