#!/usr/bin/env bash
#
# Assert scripts/check-glass-diff.sh holds its contract.
set -euo pipefail
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
note_failure() { echo "FAIL: $*" >&2; fail=1; }

run_in_repo() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  mkdir -p "$tmpdir/scripts"
  cp "$here/check-glass-diff.sh" "$here/glass-paths.sh" "$tmpdir/scripts/"
  chmod +x "$tmpdir/scripts/check-glass-diff.sh"

  git -C "$tmpdir" init -q
  git -C "$tmpdir" config user.email test@example.com
  git -C "$tmpdir" config user.name test

  (
    cd "$tmpdir"
    "$@"
  )
}

# Writes the stamp glass-diff.sh would write for the current index.
record='
  . scripts/glass-paths.sh
  key="$(glass_stamp .)"
  dir="$(git rev-parse --path-format=absolute --git-path "glass-diff/$key")"
  mkdir -p "$dir"
  printf "stamp %s\n" "$key" > "$dir/stamp"
'

stage_glass='
  mkdir -p player/lib/presentation/widgets/glass
  echo "$1" > player/lib/presentation/widgets/glass/glass_button.dart
  git add player/lib/presentation/widgets/glass/glass_button.dart
'

if ! run_in_repo scripts/check-glass-diff.sh; then
  note_failure "empty index should pass"
fi

if ! run_in_repo bash -c '
  mkdir -p player/lib/presentation/widgets/nav
  echo ok > player/lib/presentation/widgets/nav/sidebar_row.dart
  git add player/lib/presentation/widgets/nav/sidebar_row.dart
  scripts/check-glass-diff.sh
'; then
  note_failure "non-glass staged file should pass"
fi

for path in \
  player/shaders/liquid_glass.frag \
  player/lib/core/theme/liquid_glass/liquid_glass_profile.dart \
  player/lib/core/theme/depth_tokens.dart \
  player/lib/presentation/widgets/glass/glass_button.dart \
  player/lib/presentation/widgets/glass_surface.dart \
  player/tool/liquid_glass_lab/main.dart
do
  if run_in_repo bash -c "
    mkdir -p \"\$(dirname '$path')\"
    echo glass > '$path'
    git add '$path'
    scripts/check-glass-diff.sh
  "; then
    note_failure "staged $path without a diff should fail"
  fi
done

if ! run_in_repo bash -c "
  set -- one
  $stage_glass
  $record
  scripts/check-glass-diff.sh
"; then
  note_failure "staged glass with a matching diff should pass"
fi

if run_in_repo bash -c "
  set -- one
  $stage_glass
  $record
  set -- two
  $stage_glass
  scripts/check-glass-diff.sh
"; then
  note_failure "restaged glass content should need a new diff"
fi

# A stamp file that does not carry the key is not a recorded diff.
if run_in_repo bash -c "
  set -- one
  $stage_glass
  . scripts/glass-paths.sh
  dir=\"\$(git rev-parse --path-format=absolute --git-path \"glass-diff/\$(glass_stamp .)\")\"
  mkdir -p \"\$dir\"
  echo recorded > \"\$dir/stamp\"
  scripts/check-glass-diff.sh
"; then
  note_failure "a stamp without the staged key should fail"
fi

# A deletion-only commit changes rendering too.
if run_in_repo bash -c "
  set -- one
  $stage_glass
  git commit -q --no-verify -m base
  git rm -q player/lib/presentation/widgets/glass/glass_button.dart
  scripts/check-glass-diff.sh
"; then
  note_failure "a staged glass deletion without a diff should fail"
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "ok   check-glass-diff.sh"
