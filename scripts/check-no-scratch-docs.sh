#!/usr/bin/env bash
#
# Reject commits that stage planning docs under docs/.
#
# docs/ is the mkdocs docs_dir, so anything committed there is published to
# docs.mydia.dev. Specs, plans, brainstorms and research notes belong in
# design/ at the repo root, which mkdocs never reads. mkdocs.yml exclude_docs
# is the matching backstop for local builds.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}

# Keep in sync with mkdocs.yml exclude_docs.
pattern='^docs/(superpowers|plans|brainstorms|solutions|research)/'

offending="$(
  git -C "$repo_root" diff --cached --name-only --diff-filter=ACMR \
    | grep -E "$pattern" || true
)"

if [ -z "$offending" ]; then
  exit 0
fi

echo "error: planning docs under docs/ must not be committed." >&2
echo "       docs/ is published to docs.mydia.dev. Put specs and plans in design/" >&2
echo "       (see design/README.md)." >&2
echo >&2
echo "$offending" | sed 's/^/  /' >&2
exit 1
