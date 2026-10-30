#!/usr/bin/env bash
#
# Assert scripts/check-no-scratch-docs.sh holds its contract.
set -euo pipefail
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
readonly CHECK_SRC="$root/scripts/check-no-scratch-docs.sh"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

run_in_repo() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  cp "$CHECK_SRC" "$tmpdir/check-no-scratch-docs.sh"
  chmod +x "$tmpdir/check-no-scratch-docs.sh"

  git -C "$tmpdir" init -q
  git -C "$tmpdir" config user.email test@example.com
  git -C "$tmpdir" config user.name test

  (
    cd "$tmpdir"
    "$@"
  )
}

# Clean tree: nothing staged.
if ! run_in_repo ./check-no-scratch-docs.sh; then
  note_failure "empty index should pass"
fi

# Implementation files are fine.
if ! run_in_repo bash -c '
  mkdir -p lib
  echo ok > lib/example.ex
  git add lib/example.ex
  ./check-no-scratch-docs.sh
'; then
  note_failure "non-scratch staged file should pass"
fi

# Each scratch root is rejected when staged.
for path in \
  docs/superpowers/plan.md \
  docs/plans/plan.md \
  docs/brainstorms/idea.md \
  docs/solutions/learning.md \
  docs/research/notes.md
do
  if run_in_repo bash -c "
    mkdir -p \"\$(dirname '$path')\"
    echo scratch > '$path'
    git add '$path'
    ./check-no-scratch-docs.sh
  "; then
    note_failure "staged $path should fail"
  fi
done

# Design docs live outside docs/ and are committed.
if ! run_in_repo bash -c '
  mkdir -p design/specs
  echo spec > design/specs/2026-01-01-example-design.md
  git add design/specs/2026-01-01-example-design.md
  ./check-no-scratch-docs.sh
'; then
  note_failure "staged design/ file should pass"
fi

# No ignore rule in this repo may hide design docs.
if git -C "$root" check-ignore -q design/specs/example-design.md \
  || git -C "$root" check-ignore -q docs/superpowers/specs/example-design.md; then
  note_failure "design docs must not be gitignored"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "ok   check-no-scratch-docs.sh"
