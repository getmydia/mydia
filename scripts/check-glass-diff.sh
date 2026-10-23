#!/usr/bin/env bash
#
# Refuse a commit that stages Liquid Glass files without a visual diff of
# exactly that staged content. `./dev player glass-diff` records the diff;
# see player/docs/liquid-glass.md, "Visual diff".
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=scripts/glass-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/glass-paths.sh"

if git -C "$root" diff --cached --quiet -- "${GLASS_PATHS[@]}"; then
  exit 0
fi

stamp="$(glass_stamp "$root")"
dir="$(git -C "$root" rev-parse --path-format=absolute --git-path "glass-diff/$stamp")"
# glass-diff.sh writes the key into the stamp only after every comparison ran.
if [ -f "$dir/stamp" ] && grep -Fxq "stamp $stamp" "$dir/stamp"; then
  exit 0
fi

cat >&2 <<'EOF'
Liquid Glass files are staged without a visual diff for this content.
Run: ./dev player glass-diff
Then look at the side-by-side images it prints before committing.
EOF
exit 1
