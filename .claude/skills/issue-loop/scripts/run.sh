#!/usr/bin/env bash
# Runs the whole loop: triage, then a human gate, then fix, then babysit.
#
# Every phase is separately resumable, so an interrupted run picks up where it
# stopped rather than starting over.
#
# Usage: run.sh [--yolo] [--no-babysit] [issue...]
#   --yolo         skip the human gate after triage
#   --no-babysit   stop once the PRs are open

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require gh jq claude uuidgen

YOLO=0
BABYSIT=1
PASS=()
for arg in "$@"; do
  case $arg in
    --yolo)       YOLO=1 ;;
    --no-babysit) BABYSIT=0 ;;
    [0-9]*)       PASS+=("$arg") ;;
    *)            die "unknown argument: $arg" ;;
  esac
done

log "phase 1: triage"
"$SKILL_DIR/scripts/triage.sh" "${PASS[@]}"

mapfile -t APPROVED < <(issues_in_phase approved)

# When the caller named specific issues, do not sweep in ones approved by an
# earlier run.
if (( ${#PASS[@]} )); then
  mapfile -t APPROVED < <(
    comm -12 <(printf '%s\n' "${APPROVED[@]}" | sort) <(printf '%s\n' "${PASS[@]}" | sort)
  )
fi

if ! (( ${#APPROVED[@]} )); then
  log "triage approved nothing. Review the table above; force one with: fix.sh <issue>"
  exit 0
fi

if ! (( YOLO )); then
  echo
  echo "Triage approved ${#APPROVED[@]} issue(s): ${APPROVED[*]}"
  echo "Each will get its own worktree, its own agent, and its own PR."
  read -r -p "Proceed? [y/N] " reply
  [[ $reply == [yY]* ]] || { log "stopped at the gate; nothing was changed"; exit 0; }
fi

log "phase 2: fix"
"$SKILL_DIR/scripts/fix.sh" "${APPROVED[@]}"

if (( BABYSIT )); then
  log "phase 3: babysit"
  "$SKILL_DIR/scripts/babysit.sh"
fi

"$SKILL_DIR/scripts/status.sh"
