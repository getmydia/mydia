# Releasing

Mydia and the metadata-relay service release through two different mechanisms.
This page covers both.

## Mydia

Releases are draft-first. The draft is created by hand, the workflow builds
against it, and the workflow publishes it at the end. GitHub creates the git tag
at publish time, so no tag exists while the release is being built.

This shape is forced by two constraints. The repository has Immutable Releases
enabled, so assets can only be uploaded while a release is still a draft. And
GitHub Actions silently drops the `release: created` event for drafts, so the
workflow cannot trigger on the release itself and is dispatched manually
instead.

### Cutting a release

**1. Pin a commit and create the draft.**

```bash
git fetch origin
SHA=$(git rev-parse origin/master)

gh release create v0.13.0 \
  --repo getmydia/mydia \
  --target "$SHA" \
  --draft \
  --notes-file notes.md
```

Add `--prerelease` for a beta or rc.

`--target` must be a full commit SHA. A branch name is resolved once when the
workflow builds and again when GitHub creates the tag, which lets the tag land
on code that was never built. The workflow rejects a draft that targets a
branch.

Pinning also fixes what the release contains. Anything merged to master after
this point is simply not in the release, which is what you want, and the
workflow tells you about it rather than absorbing it silently.

**2. Dispatch the workflow.**

```bash
gh workflow run release.yml --repo getmydia/mydia -f version=v0.13.0
```

The workflow builds Docker images for both database variants on both
architectures, builds and signs the player for Android, iOS, macOS, Windows and
Linux, uploads the assets to the draft, and publishes it.

For a stable release it then deploys versioned documentation. Prereleases skip
the docs deploy.

### Dispatch inputs

| Input | Default | Effect |
| --- | --- | --- |
| `version` | required | Tag of an existing draft release. Ignored when `dry_run` is set. |
| `dry_run` | `false` | Build, sign and notarize everything without publishing, pushing images, or uploading to stores. |
| `accept_drift` | `false` | Proceed even though master has moved past the commit the draft targets. |
| `allow_missing` | `""` | Comma-separated platforms whose failure must not block publish: `android`, `ios`, `macos`, `windows`, `linux`, `docker`. |

### Rehearsing

Signing, notarization, the Sparkle appcast, and the Windows installer only
execute during a release, which historically meant discovering breakage while
shipping. A rehearsal runs all of it against master without side effects:

```bash
gh workflow run release.yml --repo getmydia/mydia -f dry_run=true
```

A rehearsal builds every image without pushing to ghcr, builds and signs and
notarizes every player artifact, and generates and validates the appcast. It
skips the store uploads, the asset upload, the publish step, and the docs
deploy. It needs no draft.

Run one before any release you care about, and after any change to
`release.yml`, the Dockerfile, or the player's platform directories.

The rehearsal does not exercise TestFlight or Play Store credentials, since it
stops before those calls. Credential expiry still surfaces for the first time
during a real release.

### When the workflow refuses

**"Draft targets 'master', which is a branch, not a commit."**

The draft was created without `--target <sha>`. Pin it:

```bash
gh release edit v0.13.0 --repo getmydia/mydia --target "$(git rev-parse origin/master)"
```

**"N commit(s) landed on master after this draft was cut."**

Someone merged while the release was being prepared, so the notes no longer
describe what would ship. The run summary lists the commits. Either fold them in:

```bash
gh release edit v0.13.0 --repo getmydia/mydia --target "$(git rev-parse origin/master)"
# then update the notes to cover the new commits
```

Or ship the pinned commit as-is and leave the rest for the next release:

```bash
gh workflow run release.yml --repo getmydia/mydia -f version=v0.13.0 -f accept_drift=true
```

**"Refusing to publish: windows (failure) did not succeed."**

A platform build failed. The release stays a draft and nothing was published.
Re-run the failed jobs from the Actions UI, which reuses the same run and
therefore the same build number.

If the failure is external and you need to ship without that platform, name it
explicitly:

```bash
gh workflow run release.yml --repo getmydia/mydia -f version=v0.13.0 -f allow_missing=windows
```

The published release then carries a note saying which assets are absent.

### Recovering from a failed release

Nothing is published until every gate passes, so a failed run leaves the draft
intact. Fix the cause and dispatch again with the same version.

Two things do survive a failed run. Per-arch Docker images tagged
`<version>-amd64` and `<version>-arm64` may already be in ghcr, and they are
overwritten by the next attempt. And the build number, derived from the
workflow run number, increases on every new dispatch. That is deliberate:
TestFlight and the Play Store both reject a reused build number.

## Docker tags

Every tag has a `-pg` counterpart built against PostgreSQL. The unsuffixed tag
is the SQLite build.

| Tag | Points at |
| --- | --- |
| `master`, `master-pg` | Every commit on master. Built by `ci-docker.yml`, not the release workflow. |
| `latest`, `latest-pg` | The newest published stable release. |
| `beta`, `beta-pg` | The newest published prerelease. |
| `0.13.0`, `0.13.0-pg` | That exact release. Never moves. |
| `0.13`, `0.13-pg` | The newest stable release on that minor line. |
| `0`, `0-pg` | The newest stable release on that major line. |

The floating tags only ever move forward. Publishing a v0.11.2 patch after
v0.12.0 applies `0.11.2` and `0.11`, and leaves `latest` and `0` pointing at
v0.12.0.

## Release notes

Notes are written by hand into the draft. There is no CHANGELOG and nothing is
generated from the commit range.

A patch release carries the preceding minor's notes as well as its own. Someone
upgrading from v0.11.x to v0.12.1 reads the v0.12.1 page and needs to see what
v0.12.0 changed.

## Metadata relay

The relay releases on a pushed tag rather than a dispatched draft.
`deploy-relay.yml` triggers on tags matching `metadata-relay-v*`:

```bash
git tag -a metadata-relay-v0.12.0 -m "Metadata Relay v0.12.0"
git push origin metadata-relay-v0.12.0
```

The relay lives in this repository at `metadata-relay/` but deploys entirely
separately, so its version is independent of mydia's.
