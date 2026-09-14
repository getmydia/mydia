#!/usr/bin/env bash
#
# Reject commits that stage local planning scratch under docs/.
#
# These directories are gitignored (.gitignore) and excluded from mkdocs
# (mkdocs.yml exclude_docs), but git will still commit them once tracked or
# force-added. This hook inspects the index on every commit.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}

# Keep in sync with .gitignore and mkdocs.yml exclude_docs.
pattern='^docs/(superpowers|plans|brainstorms|solutions|research)/'

offending="$(
  git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR \
    | grep -E "$pattern" || true
)"

if [ -z "$offending" ]; then
  exit 0
fi

echo "error: local planning scratch under docs/ must not be committed." >&2
echo "       These paths are gitignored and would publish to docs.mydia.dev if tracked." >&2
echo "       Move permanent reference material out of docs/ next to the code it documents." >&2
echo >&2
echo "$offending" | sed 's/^/  /' >&2
exit 1
