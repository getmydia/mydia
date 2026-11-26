# macOS dev track

## Why

Installing a master build of the player on a Mac takes six manual steps. You
dispatch Player / On-Demand Build with "Build macOS" ticked, open the finished
run, download the `mydia-player-macos-dmg` artifact, unzip it, mount the DMG,
and drag the app into Applications. The DMG is already signed and notarized.
It goes nowhere but a run artifact.

The player already has a Dev release track, and Android master builds already
publish to it through `dl.mydia.dev/index.json`. On macOS the track is hidden,
because `SparkleUpdateBackend.availableTracks` says "No macOS dev builds are
published yet." This change publishes them, so that a Mac on the Dev track
picks up each master on-demand build through Sparkle's normal update prompt.

## Goals

- A master on-demand build with "Build macOS" ticked reaches every Mac on the
  Dev track as a Sparkle update, with no other action.
- Stable and beta Macs never see a dev build.
- The Dev track can be selected in the player's settings on macOS.

## Non-goals

- **Branch builds.** They stay run artifacts, for the same reason Android's
  do (`player-ondemand.yml`, branch mode): a branch build's number could
  outrank the master build made after the merge.
- **Automatic builds.** A build still starts only from a manual On-Demand
  dispatch. No build per merge and no nightly build.
- **Local install tooling.** No `./dev player macos install` command and no
  Homebrew cask.
- **Bootstrap.** A Mac moves onto the track once, by hand: install any build,
  then pick Dev in settings.

## What exists today

| Piece | State |
| --- | --- |
| Build numbers | `scripts/build-number.sh` orders dev, beta and stable across every platform. A `dev.K` build sorts above the release it follows and below the next one. |
| Swift updater | `AppDelegate.allowedChannels(for:)` already maps the `dev` track to the `{beta, dev}` channels and accepts `setTrack("dev")`. |
| Dart updater | `SparkleUpdateBackend.availableTracks` returns `{stable, beta}`. |
| Dev index | `player-android.yml`, step "Publish the dev build to R2", uploads the APK to the `mydia-dev-builds` bucket and rewrites `index.json` in place (malformed-row filter, newest five per platform, prune-survival check, stale-file deletion). |
| Feed generator | `scripts/appcast/generate.mjs` builds `appcast.xml` from GitHub releases only. It reads the dev index for `releases.json` only. |
| macOS workflow | `player-macos.yml` signs, notarizes, staples and builds the DMG. Sparkle `sign_update` runs only when `generate_appcast` is true, which only `release.yml` sets. |

## Design

### 1. Shared index publisher

The R2 index logic moves out of `player-android.yml` into
`scripts/dev-builds/publish.sh`. It takes its inputs from environment
variables. Required: platform, local file, published file name, version and
build. Optional: a JSON object of extra fields. The script uploads the file,
reads `index.json`, adds the entry, prunes, and deletes stale files, with the
same behavior and error handling the inline step has now. The entry it writes
looks like this:

```json
{"platform": "...", "version": "...", "build": 0, "file": "...",
 "size": 0, "sha256": "...", "published_at": "...", ...extra}
```

The prune keeps the newest five builds per platform, so Android and macOS never
evict each other's builds. The Android step calls the script with no extra
fields. Its index entries stay byte for byte the same as today's.

The rclone remote stays configurable through an environment variable, so tests
can aim the script at a local directory remote.

### 2. macOS publish step

`player-macos.yml` gets a new boolean input, `publish_dev_build`, defaulting to
false, plus the R2 secrets as optional workflow secrets. When the input is true
and `dry_run` is false, the job runs these steps after "Create DMG":

1. Download the Sparkle tools. The existing step's `if` widens to
   `generate_appcast || publish_dev_build`.
2. Sign the DMG with `sign_update` and parse `edSignature` and `length`. It
   uses the same output-format check that the "Generate appcast" step uses and
   fails the step on any mismatch.
3. Read `LSMinimumSystemVersion` from the built app's Info.plist, as "Generate
   appcast" already does.
4. Call `publish.sh` with platform `macos`, the file
   `macos/mydia-player-macos-v<version>-<digest12>.dmg` (the same
   per-platform prefix Android's `android/` files use; the first twelve hex
   digits of the DMG's SHA-256 keep a re-dispatch of the same version from
   overwriting bytes a signed feed entry still describes), and these extra
   fields:
   `ed_signature`, `length` and `minimum_system_version`.

The step fails before it touches the index when any of the signature, the
length or R2 credentials is missing.

### 3. On-demand wiring

In `player-ondemand.yml`:

- The `player-macos` job passes
  `publish_dev_build: ${{ !inputs.dry_run && needs.prepare.outputs.branch_mode == 'false' }}`,
  the same expression Android uses. It also forwards the R2 secrets.
- The `player-macos` job takes the same concurrency group as Android: the
  shared `mydia-dev-builds-index` for a master build and a per-run group for a
  branch build. This way two platforms never read and rewrite `index.json` at
  the same time.
- The `appcast` job adds `player-macos` to `needs` and runs when Android or
  macOS published. Its condition stays positive: each platform is checked with
  `== 'success'`. Because one of the two jobs may have been skipped, the
  condition opens with `always()`, plus explicit checks that `prepare`
  succeeded, that the run is not a dry run, and that it is not in branch mode.

### 4. Feed generator

A new pure function, `buildDevItems(devBuilds)` in `lib/build.mjs`, turns the
macOS entries of the dev index into feed items:

| Field | Value |
| --- | --- |
| title | `Dev build <version>` |
| version (`sparkle:version`) | `build` |
| shortVersionString | `version` |
| channel | `dev` |
| minimumSystemVersion | `minimum_system_version` when present, else omitted |
| pubDate | `published_at` |
| description | A link to the master commit log, which is what `releases.json` already points dev builds at |
| enclosure | url `https://dl.mydia.dev/<file>`, signature `ed_signature`, length `length` |

The function drops an entry, with a `::warning::`, when it lacks
`ed_signature`, has a non-integer `length`, or has a malformed `published_at`.
An unsigned dev build is never fatal to the feed, which matches how
`fetchDevBuilds` already treats an unreadable index.

`generate.mjs` fetches the dev index once, before the feed is written. It
passes the index to both `buildDevItems` and `buildReleasesModel`. Release
items and dev items are merged and sorted newest first. The dev items sit
outside the `MAX_ITEMS` cap, which counts release items only. The index already
caps dev builds at five per platform.

Today `assertFeedInvariants` uses a boolean `prerelease` flag. It moves to a
`kind` field with three values: `stable`, `beta` and `dev`. Each kind must
carry its own channel: none for stable, `beta` for beta, `dev` for dev. The
assertion still runs on the merged list, so a dev item that would render
without a channel, and so be offered to every stable Mac, makes the run fail
before anything is written. Before that assertion runs, a dev item whose
`sparkle:version` equals a release item's is dropped with a warning. Without
that, a reused version override would make the duplicate check throw and
freeze stable updates. Duplicate detection still covers the merged list.

`validate.sh` gains one check: every item whose enclosure url starts with
`https://dl.mydia.dev/` carries `<sparkle:channel>dev</sparkle:channel>`. It is
a second, independent guard on the same invariant, consistent with that
script's stated purpose.

`releases.json` already models `platforms.macos.dev`. After this change that
entry has data, which is expected.

### 5. Player

In `SparkleUpdateBackend.availableTracks`, `dev` joins the set, and the comment
that explained its absence is deleted. Nothing changes in Swift.

## Failure modes

| Failure | Result |
| --- | --- |
| Sparkle signing fails or prints unexpected output | The macOS job fails before upload. The index and feed are untouched. |
| R2 upload or index write fails | The same handling Android has today, now shared. |
| An index entry has no signature (for example a hand-edited row) | The generator drops that item with a warning. The rest of the feed deploys. |
| A dev item would render without a channel | `assertFeedInvariants` throws, then `validate.sh` fails. The previously deployed feed stays live. |
| The macOS build is skipped or fails while Android publishes | The appcast still deploys for Android, the same as today. |
| A Mac on Dev when a stable release ships | Sparkle compares build numbers. The release outranks earlier `dev.K` builds, and Dev also allows `beta`, so the Mac moves forward without getting stranded. |

## Testing

- `scripts/appcast/test/build.test.mjs` covers `buildDevItems`: field mapping,
  each drop case, and the `kind` invariants, including a dev item with a
  missing channel, a duplicate version across release and dev items, and
  ordering of the merged list.
- `scripts/appcast/test/render.test.mjs` covers a rendered dev item carrying
  `sparkle:channel` `dev` and `minimumSystemVersion`.
- A `validate.sh` fixture: a feed with a `dl.mydia.dev` item that has no
  channel must fail.
- `scripts/dev-builds/publish.sh` is tested against an rclone local
  filesystem remote with these cases: bootstrap from an empty bucket,
  malformed rows dropped, five kept per platform with no cross-platform
  eviction, refusal of a build older than the five kept, and extra fields
  preserved. An Android-shaped call must produce the same entry the inline
  step writes today.
- Dart: an updated `sparkle_update_backend` test asserting that the track set
  includes `dev` and that `selectTrack(dev)` writes through.
- End to end, once merged: dispatch an On-Demand master build with macOS
  ticked. Confirm that `dl.mydia.dev/index.json` has a `macos` entry and that
  `updates.mydia.dev/appcast.xml` has a `dev` item. Then confirm that a Mac on
  the Dev track is offered the build.
