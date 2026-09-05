#!/usr/bin/env bash
# Shared configuration and state helpers for the issue-loop skill.
#
# Every phase sources this. State lives in the MAIN checkout, never in a
# worktree, so that agents scattered across per-issue worktrees all read and
# write the same files, and so that deleting a worktree loses nothing.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
STATE_DIR="${ISSUE_LOOP_STATE_DIR:-$MAIN_ROOT/.claude/issue-loop}"
export SKILL_DIR MAIN_ROOT STATE_DIR

mkdir -p "$STATE_DIR/issues" "$STATE_DIR/logs"

REPO="${ISSUE_LOOP_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo getmydia/mydia)}"
MODEL="${ISSUE_LOOP_MODEL:-sonnet}"
TRIAGE_CONCURRENCY="${ISSUE_LOOP_TRIAGE_CONCURRENCY:-10}"
FIX_CONCURRENCY="${ISSUE_LOOP_FIX_CONCURRENCY:-4}"
MAX_ROUNDS="${ISSUE_LOOP_MAX_ROUNDS:-3}"
FIX_BUDGET="${ISSUE_LOOP_FIX_BUDGET:-8}"
TRIAGE_BUDGET="${ISSUE_LOOP_TRIAGE_BUDGET:-1}"
BASE_REF="${ISSUE_LOOP_BASE_REF:-origin/master}"
export REPO MODEL TRIAGE_CONCURRENCY FIX_CONCURRENCY MAX_ROUNDS FIX_BUDGET TRIAGE_BUDGET BASE_REF

# Auto-take gate. An issue must clear every one of these to be fixed without a
# human looking at it first.
MIN_CONFIDENCE="${ISSUE_LOOP_MIN_CONFIDENCE:-0.7}"
MAX_FILES="${ISSUE_LOOP_MAX_FILES:-3}"
export MIN_CONFIDENCE MAX_FILES

log()  { printf '\033[2m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '\033[33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

state_file() { printf '%s/issues/%s.json' "$STATE_DIR" "$1"; }

# state_merge <issue> <json-patch>
# Shallow-merges the patch into the issue's state file under a lock, because
# several agents finish at once and would otherwise clobber each other.
state_merge() {
  local issue=$1 patch=$2 file
  file=$(state_file "$issue")
  (
    flock 9
    local cur
    cur=$(cat "$file" 2>/dev/null || echo '{}')
    jq -n --argjson a "$cur" --argjson b "$patch" \
      '$a * $b * {updated: (now | todateiso8601)}' >"$file.tmp"
    mv "$file.tmp" "$file"
  ) 9>"$file.lock"
}

# state_get <issue> <jq-path>
state_get() {
  local file
  file=$(state_file "$1")
  [[ -f $file ]] || return 0
  jq -r "$2 // empty" "$file" 2>/dev/null || true
}

# issues_in_phase <phase>...
issues_in_phase() {
  local wanted
  wanted=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  find "$STATE_DIR/issues" -name '*.json' -print0 2>/dev/null |
    xargs -0 -r jq -r --argjson w "$wanted" 'select(.phase as $p | $w | index($p)) | .issue' |
    sort -n
}

# throttle <max> blocks until fewer than <max> background jobs are running.
throttle() {
  while (( $(jobs -rp | wc -l) >= $1 )); do wait -n; done
}

# MCP servers are not wanted in any loop agent: they cost tokens, add latency and
# offer nothing to a triage or fix agent. `--restricted` alone does not drop
# them, so every launch pairs it with these two flags.
# (a bash array, so it is inherited by sourcing, not by export)
NO_MCP=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')

# claude_result <raw-json>
# `--output-format json` prints a JSON *array* of events. The interesting one is
# the last `type == "result"`, which carries the answer twice: `structured_output`
# already parsed (present when --json-schema was used) and `result` as a string.
# Prefer the parsed form, fall back to parsing the string, and never fail.
claude_result() {
  jq -c '
    (if type == "array" then (map(select(.type == "result")) | last) else . end) as $r
    | if $r == null then {raw: "no result event"}
      elif ($r.structured_output // null) != null then $r.structured_output
      elif ($r.result | type) == "object" then $r.result
      elif ($r.result | type) == "string" then (try ($r.result | fromjson) catch {raw: $r.result})
      else {raw: ($r | tostring)}
      end
  ' <<<"$1" 2>/dev/null || jq -n --arg s "$1" '{raw: $s}'
}

require() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null || die "missing required command: $c"
  done
}
