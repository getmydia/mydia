---
allowed-tools: Bash(git*,gh*), Read, Edit
argument-hint: [major|minor|patch|beta|rc (optional - auto-detected)]
description: Cut a draft release pinned to a commit and dispatch the release workflow
---

# Release Process

Releases are draft-first. You create a draft pinned to a commit, then dispatch
`release.yml`, which builds every platform, uploads the assets, and publishes
the draft. **Never create a git tag yourself.** GitHub creates it when the
workflow publishes the draft.

Full reference: `docs/contributing/releasing.md`.

## 1. Analyze changes since the last release

- Latest tag: `git tag --sort=-version:refname | grep -v metadata-relay | head -n1`
- Commits since: `git log <last-tag>..origin/master --oneline`
- Read the commit messages and diffs to understand what actually changed

## 2. Determine the version increment (unless given as `$1`)

- **Prefer patch (0.0.X)** for bugfixes, small improvements, or unclear changes
- **minor (0.X.0)** only for significant new features
- **major (X.0.0)** only when explicitly asked
- **beta** for a prerelease with a `-beta.N` suffix
- **rc** for a release candidate with an `-rc.N` suffix

Be conservative: when in doubt, patch. To create `beta.N`, find the existing
beta tags for that version and increment N.

The version comes from the tag. `mix.exs` reads `BUILD_VERSION` at compile
time, so there is nothing to edit and no commit to make.

## 3. Write the release notes into the repository

Open a PR adding `priv/changelog/X.Y.Z.md`. This must be the last thing merged
before you pin a commit in step 4, because the draft targets a SHA and the
image is built from it.

Categorize into these sections, skipping any that are empty:

- 🎉 **New Features**
- 🐛 **Bug Fixes**
- 🔧 **Technical Changes**
- 🚀 **Deployment Notes** (migrations, config changes, anything an operator must act on)

Keep bullets to one line each. End with:
`**Full Changelog**: https://github.com/getmydia/mydia/compare/vOLD...vNEW`

Write only what changed in this release; do not carry forward the previous
version's content. The app stacks bundled files itself for anyone who skipped
one.

**A patch release's GitHub notes carry the preceding minor's notes as well**,
so someone upgrading from v0.11.x to v0.12.1 sees the whole story on the
release page. The bundled file still holds only the patch's own changes;
concatenate the two files into the draft's notes instead of duplicating
content in `priv/changelog/`. See step 4.

## 4. Create the draft, pinned to a commit

```bash
git fetch origin
SHA=$(git rev-parse origin/master)

gh release create vX.Y.Z \
  --repo getmydia/mydia \
  --target "$SHA" \
  --draft \
  --notes-file priv/changelog/X.Y.Z.md
```

For a patch release, concatenate the patch's bundled notes with the preceding
minor's before creating the draft, so the GitHub page carries both while the
bundled file itself stays patch-only:

```bash
cat priv/changelog/X.Y.Z.md priv/changelog/X.Y.0.md > /tmp/notes.md

gh release create vX.Y.Z \
  --repo getmydia/mydia \
  --target "$SHA" \
  --draft \
  --notes-file /tmp/notes.md
```

Add `--prerelease` for beta and rc; prereleases keep hand-written notes in a
scratch file instead of `priv/changelog/`.

`--target` must be a full commit SHA. The workflow rejects a draft targeting a
branch, because a branch is resolved once at build time and again when the tag
is created, which lets the tag land on code that was never built.

The `prepare` job also refuses to build a stable release whose
`priv/changelog/<version>.md` is missing at the pinned commit, before any
platform build starts. Merge the PR from step 3 first. Prereleases are exempt,
since they ship no bundled file.

## 5. Dispatch the workflow

```bash
gh workflow run release.yml --repo getmydia/mydia -f version=vX.Y.Z
```

Then watch it:

```bash
gh run watch "$(gh run list --repo getmydia/mydia --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
```

## Important notes

- **Never create or push a git tag.** The workflow's publish step creates it.
- If `$1` is provided (major/minor/patch/beta/rc), use it instead of auto-detection
- Verify the working directory is clean before starting
- If commits land on master after the draft is cut, the workflow fails and lists
  them. Either re-point the draft (`gh release edit vX.Y.Z --target <new-sha>`)
  and update the notes, or re-dispatch with `-f accept_drift=true` to ship the
  pinned commit as-is.
- If a platform build fails, the release stays a draft. Re-run the failed jobs
  from the Actions UI. To ship without that platform, re-dispatch with
  `-f allow_missing=<platform>`.
- Before a release you care about, rehearse first:
  `gh workflow run release.yml -f dry_run=true`. It builds, signs, and notarizes
  everything without publishing or pushing.
- Prereleases tag Docker images `beta` rather than `latest`, and skip the docs
  deploy.
