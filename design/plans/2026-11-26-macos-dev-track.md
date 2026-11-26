# macOS Dev Track Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish master on-demand macOS builds to the Sparkle `dev` channel so a Mac on the Dev track updates itself.

**Architecture:** The R2 dev-index logic leaves `player-android.yml` for a shared script that both platforms call. `player-macos.yml` Sparkle-signs the DMG and publishes it through that script. The appcast generator turns macOS index entries into `channel=dev` items, guarded twice: once in JS, once in `validate.sh`. The player's Sparkle backend offers the Dev track.

**Tech Stack:** GitHub Actions, bash, jq, rclone, Node 20+ (`node:test`), Dart/Flutter.

**Spec:** `design/specs/2026-11-26-macos-dev-track-design.md`

## Global Constraints

- Branch builds never publish: `publish_dev_build` is true only when `!dry_run && branch_mode == 'false'`.
- The dev Sparkle channel name is exactly `dev`. Stable items carry no channel, beta items carry `beta`.
- Dev downloads are served from `https://dl.mydia.dev/<file>`. macOS files are `macos/mydia-player-macos-v<version>.dmg`, Android files stay `android/mydia-player-android-<version>.apk`.
- The index keeps the newest five builds per platform.
- `scripts/dev-builds/publish.sh` runs on the `xcode-27` macOS runner as well as Ubuntu. It must work on bash 3.2 (no `mapfile`, no associative arrays, no `${x,,}`) with BSD userland: size via `wc -c <`, hash via `shasum -a 256`, never `stat -c` or `sha256sum`.
- An Android publish writes the same index entry it writes today (fields `platform, version, build, file, size, sha256, published_at`, no others).
- A bad dev entry never fails the feed. It is dropped with a `::warning::`.
- No em dashes in comments or docs.

## Review Focus

1. **A dev build number equal to a release's** (a `version_override` reuse, or a re-dispatch over a tagged commit): the dev item is dropped with a warning and the feed deploys. A duplicate-version throw would freeze stable updates. Covered in Task 2 (`mergeFeedItems`).
2. **Android index entries reaching the Sparkle feed**: only `platform === 'macos'` becomes an item. Task 2 test.
3. **Index fields typed as strings** (`length: "123"` from a `jq --arg` slip): `length` must be a JSON number end to end. Task 1 asserts the type, and Task 2 drops a string `length`.
4. **Re-dispatching the same version**: the index replaces that platform's entry for the version instead of duplicating it, and leaves the other platform's entry for the same version alone. Task 1 test.
5. **The macOS runner's userland**: GNU-only flags silently break only on macOS, and the test runs on Linux. Task 1 adds a test that greps the script for `stat -c`, `sha256sum`, `mapfile` and `declare -A` and fails if any appear.

---

### Task 1: Shared dev-index publisher

**Files:**
- Create: `scripts/dev-builds/publish.sh`
- Create: `scripts/dev-builds/publish-test.sh`
- Modify: `.github/workflows/player-android.yml` (step "Publish the dev build to R2", lines 136-301)
- Modify: `.github/workflows/ci-appcast.yml` (path filter, new step)

**Interfaces:**
- Produces: `scripts/dev-builds/publish.sh`, configured entirely by environment:
  - `DEV_BUILD_PLATFORM` (required), for example `android` or `macos`
  - `DEV_BUILD_SOURCE` (required), the local file to upload
  - `DEV_BUILD_FILE` (required), the object path in the bucket, for example `macos/mydia-player-macos-v1.2.3-dev.4.dmg`
  - `DEV_BUILD_VERSION` (required), a string
  - `DEV_BUILD_NUMBER` (required), an integer
  - `DEV_BUILD_EXTRA` (optional, default `{}`), a JSON object merged into the entry
  - `DEV_BUILDS_REMOTE` (optional). When set, it is used as the rclone destination root (a local directory in tests). When unset, the script requires `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`, writes the same `~/.config/rclone/rclone.conf` the Android step writes today, and uses `r2:mydia-dev-builds`.
  - The script appends `Published <file> (build <n>).` to `$GITHUB_STEP_SUMMARY` when that variable is set.

- [ ] **Step 1: Write `publish-test.sh`, in the style of `scripts/check-no-scratch-docs-test.sh`**

Each case runs the script with `DEV_BUILDS_REMOTE=$tmp/bucket` and asserts on `$tmp/bucket/index.json` with jq:
  - `bootstrap_empty_bucket`: no `index.json` → one entry. `.build` and `.size` are numbers, `.sha256` matches `shasum -a 256` of the source, and the file exists under `bucket/`.
  - `zero_byte_index`: an empty `index.json` bootstraps the same way.
  - `malformed_rows_dropped`: an index holding `null`, `"x"` and `{"platform":"android"}` alongside one good row → only good rows remain.
  - `keeps_five_per_platform`: six android builds plus two macos builds → five android and both macos remain, and the evicted android file is deleted from `bucket/`.
  - `refuses_older_than_kept`: five android builds 10..14, then publishing build 3 exits non-zero, and the index is byte-identical to before.
  - `extra_fields_preserved`: `DEV_BUILD_EXTRA='{"ed_signature":"abc","length":42,"minimum_system_version":"13.0"}'` → those three keys are present, and `.length | type == "number"`.
  - `android_entry_shape`: no `DEV_BUILD_EXTRA` → `keys == ["build","file","platform","published_at","sha256","size","version"]`.
  - `same_version_replaced_per_platform`: publishing android 1.0.0-dev.1 twice leaves one android entry. A macos entry with the same version survives.
  - `portable_userland`: `grep -nE 'stat -c|sha256sum|mapfile|declare -A' publish.sh` finds nothing.

- [ ] **Step 2: Run it to verify it fails**

Run: `./scripts/dev-builds/publish-test.sh`
Expected: FAIL, because `publish.sh` does not exist.

- [ ] **Step 3: Write `scripts/dev-builds/publish.sh`**

Move the Android step's body here, comments included. Generalize `android` to `$DEV_BUILD_PLATFORM` in three places: the replace filter (`select(.platform != $platform or .version != $version)`), the prune-survival error message, and the `LOWEST_KEPT` query. Build the entry with `--argjson extra "$DEV_BUILD_EXTRA"` and `... + $extra`. Replace `stat -c%s` and `sha256sum` with their portable forms. Keep `set -euo pipefail` and every existing `::error::` and `::warning::`.

- [ ] **Step 4: Run it to verify it passes**

Run: `./scripts/dev-builds/publish-test.sh`
Expected: every case prints PASS, exit 0.

- [ ] **Step 5: Point the Android step at the script**

The step keeps its `if`, its secrets and its `apt-get install rclone jq`. Its `run` becomes:

```bash
DEV_BUILD_PLATFORM=android \
DEV_BUILD_SOURCE="${PLAYER_PATH}/build/app/outputs/flutter-apk/app-release.apk" \
DEV_BUILD_FILE="android/mydia-player-android-${VERSION}.apk" \
DEV_BUILD_VERSION="$VERSION" DEV_BUILD_NUMBER="$VERSION_CODE" \
./scripts/dev-builds/publish.sh
```

- [ ] **Step 6: Run the test in CI**

In `ci-appcast.yml`, add `scripts/dev-builds/**` to `paths`. Add a step before "Install dependencies" that installs rclone and jq (`sudo apt-get install -y -qq rclone jq`) and runs `../dev-builds/publish-test.sh`, since that job's working directory is `scripts/appcast`.

- [ ] **Step 7: Lint and commit**

Run: `actionlint .github/workflows/player-android.yml .github/workflows/ci-appcast.yml` (through `nix run nixpkgs#actionlint --` if it isn't on PATH) and `shellcheck scripts/dev-builds/*.sh`. Expected: no findings.

```bash
git add scripts/dev-builds .github/workflows/player-android.yml .github/workflows/ci-appcast.yml
git commit -m "refactor(ci): share the dev build index publisher"
```

---

### Task 2: Dev items in the Sparkle feed

**Files:**
- Modify: `scripts/appcast/lib/build.mjs`
- Modify: `scripts/appcast/generate.mjs`
- Modify: `scripts/appcast/validate.sh`
- Test: `scripts/appcast/test/build.test.mjs`, `scripts/appcast/test/render.test.mjs`
- Create: `scripts/appcast/test/validate.test.mjs` (spawns `validate.sh` on fixture feeds, skipping when `xmllint` is absent)

**Interfaces:**
- Consumes: dev index entries from `fetchDevBuilds()` (`dev-builds.mjs`, unchanged). Task 1 writes their macOS fields `ed_signature` (string), `length` (number) and `minimum_system_version` (string).
- Produces, in `lib/build.mjs`:
  - `export const DEV_CHANNEL = 'dev'`
  - Every item carries `kind: 'stable' | 'beta' | 'dev'`. The `prerelease` field is removed, and `capItems` reserves `kind === 'stable'`.
  - `export function buildDevItems(devBuilds): { items, warnings }`
  - `export function mergeFeedItems(releaseItems, devItems): { items, warnings }`. It drops any dev item whose `version` equals a release item's, with a warning, and returns all items sorted newest first.
  - `assertFeedInvariants(items)` checks channel by kind: stable → `null`, beta → `'beta'`, dev → `'dev'`. An unknown kind throws.

- [ ] **Step 1: Write the failing tests in `build.test.mjs`**

  - `buildDevItems maps a macos entry`: input `{platform:'macos', version:'1.2.3-dev.4', build:102300004, file:'macos/mydia-player-macos-v1.2.3-dev.4.dmg', size:5, sha256:'x', published_at:'2026-11-26T10:00:00Z', ed_signature:'SIG', length:5, minimum_system_version:'13.0'}` → `title: 'Dev build 1.2.3-dev.4'`, `version: '102300004'` (a string, like release items), `shortVersionString: '1.2.3-dev.4'`, `channel: 'dev'`, `kind: 'dev'`, `minimumSystemVersion: '13.0'`, `enclosure: {url:'https://dl.mydia.dev/macos/mydia-player-macos-v1.2.3-dev.4.dmg', signature:'SIG', length:5}`, and a `descriptionHtml` containing `https://github.com/getmydia/mydia/commits/master`.
  - `buildDevItems ignores android`: an android entry → zero items and zero warnings.
  - `buildDevItems drops unsigned, string length, bad date`: each case gives zero items and one warning naming the file.
  - `buildDevItems omits a missing minimum system version`: `minimumSystemVersion === null`.
  - `mergeFeedItems drops a dev item colliding with a release`: release version `'102300004'` plus a dev item with the same version → one item (the release) and one warning.
  - `mergeFeedItems sorts newest first across kinds`.
  - `assertFeedInvariants rejects a dev item without channel`: `{kind:'dev', channel:null, ...}` throws `/dev item must carry the dev channel/`.
  - `assertFeedInvariants rejects an unknown kind`.
  - Update the existing tests that build items by hand from `prerelease:` to `kind:`.

- [ ] **Step 2: Write the failing render test**

In `render.test.mjs`, `renderItem` on a dev item contains `<sparkle:channel>dev</sparkle:channel>` and `<sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>`.

- [ ] **Step 3: Write the failing validate test**

In `validate.test.mjs`, two fixtures written to a temp dir. Both contain one stable item from `github.com`. The first has a second item with url `https://dl.mydia.dev/macos/x.dmg` and channel `dev`, and `validate.sh` exits 0. The second has the same item with no channel, and `validate.sh` exits non-zero with stderr matching `/dl\.mydia\.dev.*dev channel/`.

- [ ] **Step 4: Run them to verify they fail**

Run: `cd scripts/appcast && npm test`
Expected: FAIL on the new tests (`buildDevItems is not a function`, the validate fixture exits 0).

- [ ] **Step 5: Implement**

  - `build.mjs`: add `kind`, `DEV_CHANNEL`, `buildDevItems`, `mergeFeedItems`, and the kind-based invariants, with error text `${title}: dev item must carry the dev channel`. `buildDevItems` validates `ed_signature` (a non-empty string), `Number.isInteger(length)` and `toRfc822(published_at)` (catch its throw). It uses `DEV_BASE_URL` from `releases-json.mjs`.
  - `generate.mjs`: fetch `devBuilds` once, before the feed is built. Then run `buildItems`, then `buildDevItems(devBuilds)`, then `mergeFeedItems`. Print every warning as `::warning::`, then `assertFeedInvariants(merged)`. Render `merged`, and pass the same `devBuilds` to `buildReleasesModel`. The log line reports the counts per kind.
  - `validate.sh`: after the per-item loop, count `item[enclosure[starts-with(@url,'https://dl.mydia.dev/')] and not(*[local-name()='channel' and text()='dev'])]`. If the count is nonzero, print `::error::<n> item(s) served from dl.mydia.dev lack the dev channel; stable clients would be offered a dev build` and exit 1. Extend the closing summary line with the dev count.

- [ ] **Step 6: Run them to verify they pass**

Run: `cd scripts/appcast && npm test`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/appcast
git commit -m "feat(appcast): publish macOS dev builds on the dev channel"
```

---

### Task 3: macOS workflow publishes the dev build

**Files:**
- Modify: `.github/workflows/player-macos.yml`

**Interfaces:**
- Consumes: `scripts/dev-builds/publish.sh` (Task 1). Task 2 reads the extra fields `ed_signature`, `length` and `minimum_system_version`.
- Produces: the `workflow_call` input `publish_dev_build` (boolean, default `false`), and the optional secrets `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.

- [ ] **Step 1: Add the input and the secrets**

The input's description is `Sign the DMG for Sparkle and publish it to the dev build index (dl.mydia.dev)`. Each new secret gets `required: false`.

- [ ] **Step 2: Widen "Download Sparkle tools"**

Its `if` becomes `${{ inputs.generate_appcast || (inputs.publish_dev_build && !inputs.dry_run) }}`.

- [ ] **Step 3: Add the step "Publish the dev build to R2" after "Create DMG", before the artifact upload**

`if: ${{ inputs.publish_dev_build && !inputs.dry_run }}`. Its env carries the three R2 secrets, `SPARKLE_EDDSA_KEY`, `VERSION` and `VERSION_CODE`. The working directory is the one "Generate appcast" uses. In order:
  1. Fail with `::error::` if `SPARKLE_EDDSA_KEY` is empty.
  2. `command -v rclone || brew install rclone`, and the same for `jq`.
  3. `SIGNATURE=$(sign_update ...)`, invoked exactly as "Generate appcast" does, then the same `^sparkle:edSignature="[^"]+" length="[0-9]+"$` check. Extract `ED_SIG` and `LENGTH` with `sed`.
  4. Read `MIN_OS` with PlistBuddy, as "Generate appcast" does.
  5. `DEV_BUILD_EXTRA=$(jq -nc --arg s "$ED_SIG" --argjson l "$LENGTH" --arg m "$MIN_OS" '{ed_signature:$s,length:$l,minimum_system_version:$m}')`
  6. Call `publish.sh` with platform `macos`, source `Mydia Player.dmg`, file `macos/mydia-player-macos-v${VERSION}.dmg`, and the version and build number. Use `$GITHUB_WORKSPACE/scripts/dev-builds/publish.sh`.

- [ ] **Step 4: Lint**

Run: `actionlint .github/workflows/player-macos.yml`
Expected: no findings. Then confirm that `release.yml`'s call to this workflow passes neither new input nor new secret, so it needs no change: `grep -n -A12 'player-macos.yml' .github/workflows/release.yml`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/player-macos.yml
git commit -m "feat(ci): publish macOS dev builds to the dev build index"
```

---

### Task 4: On-demand wiring

**Files:**
- Modify: `.github/workflows/player-ondemand.yml` (`player-macos` job around line 253, `appcast` job around line 340)

**Interfaces:**
- Consumes: Task 3's input and secrets.

- [ ] **Step 1: Configure the `player-macos` job**

  - Add the same `concurrency` block the Android job has, with the branch-mode group renamed `player-ondemand-macos-{0}`.
  - Add `publish_dev_build: ${{ !inputs.dry_run && needs.prepare.outputs.branch_mode == 'false' }}`.
  - Add the secrets `SPARKLE_EDDSA_KEY`, `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.
  - Add a comment pointing at the Android job's explanation of the shared group, not a copy of it.

- [ ] **Step 2: Configure the `appcast` job**

`needs: [prepare, player-android, player-macos]`, and:

```yaml
if: ${{ always() && !inputs.dry_run && needs.prepare.result == 'success' && needs.prepare.outputs.branch_mode == 'false' && (needs.player-android.result == 'success' || needs.player-macos.result == 'success') }}
```

Rewrite the comment above it. `always()` is now needed, because either platform job may be skipped, and the checks stay positive `== 'success'` for the reason the existing comment gives.

- [ ] **Step 3: Lint and commit**

Run: `actionlint .github/workflows/player-ondemand.yml`
Expected: no findings.

```bash
git add .github/workflows/player-ondemand.yml
git commit -m "feat(ci): wire macOS dev publishing into on-demand builds"
```

---

### Task 5: Offer the Dev track on macOS

**Files:**
- Modify: `player/lib/core/update/backends/sparkle_update_backend.dart:48-51`
- Test: `player/test/core/update/backends/track_selection_test.dart:431-450`

- [ ] **Step 1: Update the test**

Rename it to `'Sparkle offers stable, beta and dev, and applies a switch'`. It expects `availableTracks == {UpdateTrack.stable, UpdateTrack.beta, UpdateTrack.dev}`, and that `selectTrack(UpdateTrack.dev)` returns `TrackSwitchApplied` with `written == UpdateTrack.dev` and `currentTrack == UpdateTrack.dev`.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd player && flutter test test/core/update/backends/track_selection_test.dart`
Expected: FAIL on the set comparison.

- [ ] **Step 3: Implement**

`availableTracks` returns all three tracks. Delete the "No macOS dev builds are published yet" comment. If `TrackSwitchNotPublished`'s `macos` flag and its macOS copy now have no producer, check with `grep -rn 'macos: true' player/lib`. If not, leave them: Sparkle still guards with `availableTracks.contains`.

- [ ] **Step 4: Run it to verify it passes**

Run: `cd player && flutter test test/core/update/`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/update/backends/sparkle_update_backend.dart player/test/core/update/backends/track_selection_test.dart
git commit -m "feat(player): offer the Dev update track on macOS"
```

---

## After merge

1. Dispatch Player / On-Demand Build on `master` with "Build macOS" ticked.
2. `curl -s https://dl.mydia.dev/index.json | jq '.builds[] | select(.platform=="macos")'` shows the build with `ed_signature`.
3. `curl -s https://updates.mydia.dev/appcast.xml | grep -B3 -A8 '<sparkle:channel>dev'` shows one dev item.
4. On the Mac, install that build once, switch Settings to the Dev track, and confirm the next master build is offered.
