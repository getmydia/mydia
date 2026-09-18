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

**1. Write the release notes into the repository.**

Open a PR adding `priv/changelog/0.13.0.md`, containing only what changed in
this release. Do not carry forward the previous version's content; the app
stacks releases itself for anyone who skipped one.

This must be the last thing merged before you pin a commit, because the draft
targets a SHA and the image is built from it. The workflow refuses to build a
stable release whose notes file is missing at the pinned commit, failing in
`prepare` before any platform build starts.

Prereleases are exempt. They keep hand-written notes and ship no bundled file.

**2. Pin a commit and create the draft.**

```bash
git fetch origin
SHA=$(git rev-parse origin/master)

gh release create v0.13.0 \
  --repo getmydia/mydia \
  --target "$SHA" \
  --draft \
  --notes-file priv/changelog/0.13.0.md
```

Add `--prerelease` for a beta or rc.

`--target` must be a full commit SHA. A branch name is resolved once when the
workflow builds and again when GitHub creates the tag, which lets the tag land
on code that was never built. The workflow rejects a draft that targets a
branch.

Pinning also fixes what the release contains. Anything merged to master after
this point is simply not in the release, which is what you want, and the
workflow tells you about it rather than absorbing it silently.

**3. Dispatch the workflow.**

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
| `allow_missing` | `""` | Comma-separated platforms whose failure must not block publish: `android`, `ios`, `macos`, `windows`, `linux`, `flatpak`, `docker`. |

### Patch releases

A patch release's GitHub notes carry the preceding minor's notes as well, so
someone reading the release page sees the whole story. The bundled file still
holds only the patch's own changes, so the app never shows the same content
twice. Concatenate at release time:

```bash
cat priv/changelog/0.13.1.md priv/changelog/0.13.0.md > /tmp/notes.md

gh release create v0.13.1 \
  --repo getmydia/mydia \
  --target "$SHA" \
  --draft \
  --notes-file /tmp/notes.md
```

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

### The macOS update feeds

Two Sparkle feeds exist, and they serve different populations.

| Feed | Contents | Who reads it |
| --- | --- | --- |
| `releases/latest/download/appcast.xml` | One item, the newest stable | Apps installed before the beta channel shipped |
| `updates.mydia.dev/appcast.xml` | Up to 20 items across both channels | Every app installed since |

The first is the per-release `appcast.xml` asset the `player-macos` job signs and
uploads. It must keep shipping on every release. It is the only route by which
an older install reaches a build that points at the new feed, and it is the
input the merged feed is built from. Its two validation steps in `release.yml`
assume a single item and must not be rewritten.

The second is rebuilt by `deploy-appcast.yml`, which `release.yml` calls after a
successful publish. It is regenerated from scratch each time, so re-running it is
always safe:

```bash
gh workflow run deploy-appcast.yml --repo getmydia/mydia
```

Run that after any release where the appcast job failed, and after manually
editing or deleting a release.

The Pages project must be created with `master` as its production branch,
for example `wrangler pages project create mydia-appcast --production-branch master`.
The deploy passes `--branch master` explicitly because the workflow checks
out a pinned commit and cannot infer a branch name. If the project's
production branch is anything else, every deploy lands on a preview URL and
`updates.mydia.dev` keeps serving the previous feed.

Because `releases/latest/download/` never resolves to a prerelease, a change to
`SUFeedURL` only reaches users through a **stable** release. Shipping such a
change in a prerelease migrates nobody.

**Backfill before the first release, not after.** Before cutting the first
release that ships an `SUFeedURL` pointing at `updates.mydia.dev`, dispatch
`deploy-appcast.yml` manually and confirm `https://updates.mydia.dev/appcast.xml`
serves a feed:

```bash
gh workflow run deploy-appcast.yml --repo getmydia/mydia
curl -fsSL https://updates.mydia.dev/appcast.xml
```

Doing this after that release ships instead of before it means every app that
updates in the meantime starts polling a URL serving nothing, and has no
recovery path until the feed exists.

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

**"v0.13.0 has no bundled release notes at priv/changelog/0.13.0.md in commit ab12cd34ef56."**

The notes PR from step 1 never got merged, or was merged after this draft was
already pinned. Write `priv/changelog/0.13.0.md`, merge it, then re-pin the
draft to the new commit and dispatch again:

```bash
gh release edit v0.13.0 --repo getmydia/mydia --target "$(git rev-parse origin/master)"
gh workflow run release.yml --repo getmydia/mydia -f version=v0.13.0
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

## Flatpak channels

The player publishes to two self-hosted OSTree repositories on Cloudflare R2.
The channel comes from the draft's prerelease flag, the same flag that decides
between the `beta` and `latest` Docker tags.

| Remote | Repo file | Fed by | History kept |
| --- | --- | --- | --- |
| `mydia` | `https://flatpak.mydia.dev/mydia.flatpakrepo` | Published stable release | 5 commits |
| `mydia-beta` | `https://flatpak.mydia.dev/mydia-beta.flatpakrepo` | Published prerelease | 2 commits |

Both ship `dev.mydia.player`, distinguished by OSTree branch. `flatpak-publish`
runs after `publish`, so a rehearsal never touches R2.

The manifest pins `org.gnome.Platform` 50 and the `llvm21` SDK extension built
for freedesktop 25.08. Those two move together: a newer GNOME runtime sits on a
newer freedesktop base and needs the matching LLVM extension. The pinned
runtime eventually goes end of life and nothing detects that automatically, so
check it when cutting a release.

Codecs come from `org.freedesktop.Platform.codecs-extra`, which the GNOME
runtime declares itself and flatpak installs automatically. The older
`org.freedesktop.Platform.ffmpeg-full` extension does not exist for freedesktop
25.08 and cannot be used with this runtime.

### Building one locally

`./dev player flatpak build` runs the same `flatpak-builder` invocation as the
`flatpak-build` CI job, then `install` and `run` deploy and launch it:

```bash
./dev player flatpak build      # 30-90 minutes cold
./dev player flatpak install    # installs --user from the staged repo
./dev player flatpak run
./dev player flatpak clean      # reclaims ~270M when you are done
```

Two things the bare `flatpak-builder` command does not do for you, and which
the wrapper handles:

- **appstreamcli must be present on the host.** `flatpak-builder` shells out to
  it during export, so without it the build fails at the very last step, after
  mpv, libplacebo, libass, Flutter and the Rust cdylib have all compiled. The
  wrapper resolves it alongside `flatpak-builder`, through `nix shell` when the
  host carries neither.
- **Build state goes in the main checkout, never a worktree.** The
  `.flatpak-builder` cache is then shared rather than rebuilt per worktree, the
  `staged` remote keeps resolving after a worktree is deleted, and the 80M
  `build-dir` stays away from the `dart-analyze` pre-commit hook, which does not
  read `.gitignore` and blocks every commit once it starts walking build output.

Override any of the three paths with `MYDIA_FLATPAK_BUILD_DIR`,
`MYDIA_FLATPAK_STATE_DIR` or `MYDIA_FLATPAK_REPO`.

### First-time setup

One-time operator actions. The release job fails without them.

1. Create an R2 bucket named `mydia-flatpak`, attach `flatpak.mydia.dev` to it
   and enable public access.
2. Create an R2 API token with object read and write on that bucket.
3. Generate the signing key on a trusted machine, not in CI. The
   `--pinentry-mode loopback` flag is required even for an unprotected key, or
   gpg fails with "No pinentry" on a headless machine:

   ```bash
   gpg --batch --pinentry-mode loopback --passphrase '' \
     --quick-generate-key "Mydia Flatpak Signing <releases@mydia.dev>" rsa4096 sign never
   KEYID=$(gpg --list-keys --with-colons releases@mydia.dev | awk -F: '/^fpr:/ {print $10; exit}')
   gpg --export-secret-keys --armor "$KEYID" | base64 | tr -d '\n' > flatpak-signing-key.b64
   gpg --export --armor "$KEYID" > player/flatpak/flatpak-signing-key.pub.asc
   echo "$KEYID"
   ```

4. Back up `flatpak-signing-key.b64` somewhere other than GitHub. See below.
5. Add the secrets `FLATPAK_GPG_PRIVATE_KEY` (contents of the `.b64` file),
   `FLATPAK_GPG_KEY_ID` (the fingerprint), `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`
   and `R2_SECRET_ACCESS_KEY`.
6. Commit `player/flatpak/flatpak-signing-key.pub.asc`. The public half is not
   a secret, and `make-flatpakrepo.sh` embeds it in both repo files.

The existing `CLOUDFLARE_API_TOKEN` is a Pages deploy token and cannot do S3
auth against R2.

### Rolling back a bad Flatpak publish

Pruning keeps previous commits, so a bad publish is recoverable. From a machine
with the signing key and R2 credentials:

```bash
rclone sync r2:mydia-flatpak/stable ./live-repo --create-empty-src-dirs
ostree log --repo=live-repo app/dev.mydia.player/x86_64/stable
ostree reset --repo=live-repo app/dev.mydia.player/x86_64/stable <previous-commit>
flatpak build-update-repo --gpg-sign=$GPG_KEY_ID live-repo
./player/flatpak/sync-repo.sh ./live-repo r2:mydia-flatpak/stable
```

Anyone who already updated moves back on their next `flatpak update`.

### If the signing key is lost

The public key is pinned inside every `.flatpakrepo` users added, so a lost
private key breaks updates for every existing install. Recovery means shipping
new repo files and asking users to re-add the remote. Keep a backup outside
GitHub Actions.

## iOS TestFlight tracks

iOS ships through two App Store Connect external groups. The names are matched
exactly by App Store Connect, and `Pre-release` carries a hyphen and a capital
P:

| Group | Public link | Receives |
| --- | --- | --- |
| `Beta` | `https://testflight.apple.com/join/KFSYxaQP` | stable releases, refresh builds |
| `Pre-release` | `https://testflight.apple.com/join/XTvarNBK` | everything |

The `Beta` group holds the link published in the README, on the site and in the
user documentation, which is why it carries stable despite the name. The
`Pre-release` group is a superset rather than prereleases alone, so a tester
there receives a stable release as an ordinary update instead of sitting on a
beta until the next cycle opens.

`release.yml` picks the groups from `is_prerelease` and passes them to
`player-ios.yml`, which both it and the refresh cron call.

### The refresh cron

TestFlight deletes a build 90 days after upload, and the installed app then
refuses to launch. The `Beta` group is topped up only by stable releases, and
the gap between v0.9.0 and v0.10.0 was 73 days.

`player-ios-refresh.yml` runs weekly. When the newest build passes 60 days it
rebuilds the current stable tag and uploads it to both groups, then records the
refresh as an `ios-refresh/YYYY-MM-DD` tag. `scripts/ios-refresh-due.sh` makes
that decision and `scripts/check-ios-refresh-due.sh` tests it, which is the only
way it can be tested: a `workflow_dispatch` workflow only triggers for a file on
the default branch, and schedules only run there, so nothing about this workflow
is exercisable from a pull request.

Refresh build numbers use the `+refresh.N` suffix from the "Versioning and
build numbers" table below, with `N` computed as `run_number % 99 + 1` rather
than by counting `ios-refresh/*` marker tags, so it never depends on this
workflow's own marker push landing. Two refreshes of the same marketing
version are at least 60 days, and therefore many scheduled runs, apart, so the
modulo does not repeat within that window. Apple rejects a reused build number
for a marketing version it already holds, which is exactly what a repeat
would risk.

To force one: `gh workflow run player-ios-refresh.yml -f force=true`. Add
`-f dry_run=true` to build without uploading or moving the marker tag.

## Release tracks

The player follows one of three tracks, picked in Settings:

| Track | Wire name | What it carries |
| --- | --- | --- |
| Stable | `stable` | Published releases. The default. |
| Beta | `beta` | Prerelease builds, a few weeks ahead of stable and less tested. |
| Dev | `dev` | Builds straight from development, published when a maintainer asks for one. Expect rough edges. |

The wire names, the labels and the descriptions above all come from
`player/lib/core/update/update_track.dart`, the one place that has to agree
with `releases.json` and the stored preference on what each track is called.

### The feed

`https://updates.mydia.dev/releases.json` describes each platform's newest
build on each track. It is generated in the same run as the macOS appcast, by
`scripts/appcast/generate.mjs` (deployed by `deploy-appcast.yml`), so the two
outputs can never disagree with each other. A platform with nothing published
on a track simply has no key for it; macOS and Flatpak have no `dev` key
because neither publishes dev builds.

**Selecting a lower track never downgrades an install.** The stored track
only changes what the next check compares against; it never forces an install
by itself, and on Android the OS enforces the rest, since `versionCode` only
moves forward. A device that is already ahead of the chosen track just stays
there until that track publishes something newer. The in-app track picker
says as much, in the running build's own version number, whenever it detects
this.

### Dev builds

`player-ondemand.yml` is the only workflow that publishes to the dev track,
and only for Android. Its Android job uploads the APK to the
`mydia-dev-builds` R2 bucket (served at `https://dl.mydia.dev`) and rewrites
the bucket's `index.json`, keeping the five newest builds per platform and
deleting whatever falls out of that window in the same run. `deploy-appcast.yml`
reads that index the next time it runs and folds it into `releases.json`;
publishing a dev build does not refresh the feed by itself, so dispatch
`deploy-appcast.yml` afterward if the build needs to be visible before the
next real release does that for you. A missing or unreachable index is
treated as "no dev track" rather than a failed feed build, the same way a
release with no DMG is skipped rather than aborting the appcast.

**One-time operator action.** The `mydia-dev-builds` bucket, its public
hostname `dl.mydia.dev`, and an R2 token scoped to just that bucket
(`R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`) are account
configuration that nothing in this repository creates. All three have to
exist before `player-ondemand.yml` is dispatched with Android enabled, or the
publish step fails loudly instead of silently skipping.

### Switching per platform

| Platform | Tracks offered | Switching |
| --- | --- | --- |
| Windows | Stable, Beta | In app, applies immediately |
| Linux (tarball) | Stable, Beta | In app, applies immediately |
| Linux (Flatpak) | Stable, Beta | Shown, but not switchable in app: it hands back a `flatpak install` command to run instead |
| macOS | Stable, Beta | In app, through Sparkle's own channel setting |
| Android (sideloaded) | Stable, Beta, Dev | In app, applies immediately |
| Android (Play Store install) | None | No updater at all; see below |
| iOS | None | No in-app picker; switch by joining the other TestFlight group |
| Web | None | Served by your own Mydia server; nothing to switch |

Flatpak and iOS are the two platforms that cannot make the switch from inside
the app. Flatpak's branch lives outside the sandbox, so the settings screen
hands back the `flatpak install` command instead of pretending the tap
worked, the same command in "Flatpak channels" above. iOS has no in-app
picker at all, because a TestFlight build belongs to whichever external group
installed it; switching means joining the other group through the links in
"iOS TestFlight tracks" above instead.

A copy installed from the Play Store gets no update backend at all, not a
disabled one. This is deliberate, not a gap: Play forbids an app it
distributes from updating itself by any mechanism other than Play's own, so a
Play install goes without a track picker rather than risk shipping one that
works. The APK at `mydia.dev/download/android` is a sideloaded install and
updates itself, which is why it is the one the README links to.

## On-demand player testing builds

When testing changes on master or feature branches before cutting a formal
release, `.github/workflows/player-ondemand.yml` allows building, signing, and
distributing player binaries on demand across any combination of supported platforms.

### Dispatching

Trigger the workflow from the GitHub Actions UI ("Player / On-Demand Build") or via the GitHub CLI:

```bash
# Build default mobile platforms (iOS & Android) from master and upload to internal store tracks
gh workflow run player-ondemand.yml --repo getmydia/mydia

# Build a specific branch or commit
gh workflow run player-ondemand.yml --repo getmydia/mydia -f ref=feat/my-feature

# Build all platforms without uploading to stores
gh workflow run player-ondemand.yml --repo getmydia/mydia \
  -f build_macos=true -f build_windows=true -f build_linux=true \
  -f upload_to_stores=false

# Test build and sign pipeline without uploading (dry run)
gh workflow run player-ondemand.yml --repo getmydia/mydia -f dry_run=true
```

### Dispatch inputs

| Input | Type | Default | Description |
| --- | --- | --- | --- |
| `ref` | string | `master` | Git branch, commit SHA, or tag to build. |
| `build_ios` | boolean | `true` | Build iOS (TestFlight / IPA). |
| `build_android` | boolean | `true` | Build Android (Play Store internal track / APK / AAB). |
| `build_macos` | boolean | `false` | Build macOS (signed & notarized DMG). |
| `build_windows` | boolean | `false` | Build Windows (Inno Setup installer). |
| `build_linux` | boolean | `false` | Build Linux (`.tar.gz` bundle). |
| `upload_to_stores` | boolean | `true` | Upload iOS build to TestFlight (internal testers). |
| `version_override` | string | `""` | Custom version string (e.g. `0.14.0-dev.42`). If empty, auto-derived. |
| `dry_run` | boolean | `false` | Build and sign without uploading to TestFlight. |

### Versioning and build numbers

Unless overridden by `version_override`, the version string is derived
automatically from the latest release tag as
`<major>.<next_minor>.0-dev.<run_number>` (for example, `0.14.0-dev.42`). The
workflow refuses to derive one once `run_number` passes 299, since that is the
ceiling of the dev band below, and asks for an explicit `version_override`
instead.

Every workflow that mints a build number, this one, `release.yml`, and
`player-ios-refresh.yml`, calls the same `scripts/build-number.sh <version>` to
turn a version string into the integer that Android's `versionCode` and
Apple's `CFBundleVersion` both use:

    build = major*10_000_000 + minor*100_000 + patch*1_000 + slot

| Suffix | Slot | Range |
| --- | --- | --- |
| `dev.N` | `N` | 0-299 |
| `alpha.N` | `300 + N` | 300-499 |
| `beta.N` | `500 + N` | 500-699 |
| `rc.N` | `700 + N` | 700-899 |
| *(none, stable)* | `900` | 900 |
| `+refresh.N` | `900 + N` | 901-999 |

The suffix keyword is case-insensitive and the dot before the counter is
optional (`rc13` parses the same as `rc.13`), because 36 tags predating this
scheme already used the bare form (`v0.8.1-rc13`, `v0.9.0-beta2`).
`+refresh.N` has no such history and always requires the dot.

Deriving the number from the version, instead of from `github.run_number` with
a per workflow offset the way this used to work, is what makes a track switch
possible on Android: the OS refuses to install a `versionCode` lower than the
one already running, so a number that follows version order is what lets a
device move from a dev build to a beta and on to the stable of the same
version. The old per workflow offsets were unrelated to version order, so an
on-demand build outranked every future release and permanently blocked
updates on any device that had installed one. `scripts/build-number.sh` is
the single source for this table; read it, not this page, before changing any
workflow that calls it.

Android test builds still are not uploaded to Google Play Console, but not for
the reason this used to say. They are the dev track's own build, published to
`https://dl.mydia.dev` and picked up by anyone who chose Dev in Settings (see
"Release tracks" below), which is a complete distribution path of its own.
Google Play's requirement that `versionCode` only increase no longer enters
into it: `scripts/build-number.sh` already keeps a dev build's number below
the beta and stable of the same version, so there is nothing left for it to
leapfrog.

### Distribution channels

- **TestFlight Internal Testers:** When `upload_to_stores` is true, iOS builds are uploaded to App Store Connect without associating external tester groups (`distribute_external: false`). Builds are distributed immediately to App Store Connect internal team members, avoiding Apple's external Beta App Review delay.
- **Workflow Artifacts:** All built binaries are uploaded as GitHub Actions artifacts attached to the workflow run (retained for 30 days):
  - Android: signed release universal APK (`mydia-player-android-apk`) and Android App Bundle (`.aab`) ready for direct sideloading and testing on Android phones and TVs
  - macOS: signed and notarized DMG disk image
  - Windows: signed Inno Setup executable installer
  - Linux: standalone `.tar.gz` bundle
  - iOS: zipped `.xcarchive` and IPA artifacts

## Release notes

Notes are authored into `priv/changelog/<version>.md` and tracked in the
repository. The app compiles that file into the image, and the draft's
GitHub notes are produced from it too. Nothing is generated from the commit
range.

The `## Player` section has a second consumer. `scripts/testflight-notes.sh`
extracts it during the release run and it becomes TestFlight's "What to Test",
so it is what beta testers read on their phones. Apple caps that field at 4000
characters; anything longer is trimmed to whole bullets with a link to the
release page. A prerelease, which ships no bundled file, gets a summary of the
commit subjects touching `player/` since the previous tag instead. The computed
text is echoed into the `Prepare` job's step summary on every run, including a
dry run, so it can be read before the build finishes.

A patch release's GitHub notes carry the preceding minor's notes as well as
its own, produced by concatenating the two bundled files. The bundled file
itself holds only the patch's own changes, since the app stacks releases
itself for anyone who skipped one.

## Metadata relay

The relay releases on a pushed tag rather than a dispatched draft.
`deploy-relay.yml` triggers on tags matching `metadata-relay-v*`:

```bash
git tag -a metadata-relay-v0.12.0 -m "Metadata Relay v0.12.0"
git push origin metadata-relay-v0.12.0
```

The relay lives in this repository at `metadata-relay/` but deploys entirely
separately, so its version is independent of mydia's.
