# Player CI Real Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CI plays a real file on Linux and macOS and fails when the player runs but behaves wrong.

**Architecture:** Linux gets `integration_test/playback_test.dart`, registered in `all_tests.dart`, so it runs inside the existing `player-e2e` NixOS VM test. It mounts the real `PlayerScreen` with a real media_kit `Player` on clips generated on the client VM, and reads mpv properties. macOS gets a new `Integration / macOS` job in `ci-player.yml` running the existing `mac_surface_test.dart` and `RunnerTests`. A shared shell guard fails either job when fewer tests passed than a pinned minimum.

**Tech Stack:** Flutter 3.50.1 `integration_test`, media_kit / libmpv, NixOS VM tests, GitHub Actions, bash + jq.

**Spec:** `design/specs/2026-11-28-player-ci-real-playback-design.md`

## Global Constraints

- Work only in this worktree. Run git from the worktree root; commit with `git commit -F <msgfile>`, one commit per step that says "Commit", then check `git show --stat HEAD` and `git status --porcelain`. Stage every intended path first: the hook stashes unstaged changes. Never `--no-verify`.
- Player commands go through `./dev` from the repo root (`./dev flutter analyze`, `./dev player e2e`). Run `./dev player setup` once before the first Flutter command.
- No em dashes in prose, comments or commit messages. No real film or TV titles in fixtures.
- Conditions are awaited with a timeout, never a fixed sleep.
- Every precondition in a test is an `expect` or `fail`. No early `return` that lets a test pass without asserting.
- No retries around a flaky test.
- Never cite `.superpowers/` or task numbers in code or docs.
- Dart: `debugPrint`, never `print`. `flutter analyze` must stay clean.
- Each task's report states what was run and its real output. A check that could not be run is reported as not run.

## Review Focus

- **Clip missing on the client.** `MYDIA_E2E_CLIPS` set but a file absent must fail the test by name, not skip. Pinned in Task 1.
- **mpv never produces a frame** (no GL, dead display link). The test must time out with the mpv log tail in the failure message, not hang until the VM's 1200 s limit. Pinned in Task 1.
- **A test is skipped or the file is dropped from `all_tests.dart`.** The count guard must go red. Pinned in Task 4.
- **The reporter JSON is missing or truncated** (app crashed mid-run). The guard must fail, not read zero tests as "nothing to check". Pinned in Task 4.
- **macOS runner without an HDR display.** HDR cases skip with a logged reason; every other case still runs and the pinned minimum proves it. Pinned in Task 5.

## Deviation from the spec

The spec says the Linux test pairs and opens the seeded movie from the server. This plan mounts `PlayerScreen` on a local clip instead, as `mac_surface_test.dart` does. None of the five escapes depends on the server, `p2p_streaming_test.dart` already covers bytes arriving, and a local clip removes the claim code, pairing and network from a test about rendering. Task 6 updates the spec to match.

`mac_surface_test.dart` keeps its own private rig. It cannot be run on Linux, so refactoring it into a shared helper here would be an unverifiable change to the only macOS playback test. The Linux helper is new and small.

---

### Task 1: Linux harness, decode and render-path assertions

**Files:**
- Create: `player/integration_test/helpers/playback_rig.dart`
- Create: `player/integration_test/playback_test.dart`
- Modify: `player/integration_test/all_tests.dart` (register `group('playback', playback.main)` last)
- Modify: `scripts/e2e/run-tests.sh` (generate clips, pass the define)
- Modify: `nix/tests/player-e2e.nix` (client gets `pkgs.ffmpeg`)

**Interfaces:**
- Produces, in `playback_rig.dart`:
  - `const e2eClipsDir = String.fromEnvironment('MYDIA_E2E_CLIPS');`
  - `String clipPath(String name)`; clip names `const sdrClip = 'e2e_sdr.mp4'`, `const subsClip = 'e2e_subs.mkv'`, `const subtitleText = 'Mydia playback subtitle check'`
  - `Future<PlaybackRig> pumpPlayerScreen(WidgetTester tester, String clip)`: mounts the real `PlayerScreen` on a local file with a real `Player`. Read `mac_surface_test.dart` (`_Rig`, `_pump`, the imports from `../test/presentation/screens/player/`) for how to build the screen with a scripted transport and fake session, minus everything `MpvSurface`.
  - `class PlaybackRig { NativePlayer get native; Future<String> prop(String name); Future<void> close(WidgetTester tester); List<String> get mpvLog; }`
  - `Future<void> waitFor(WidgetTester tester, String what, FutureOr<bool> Function() condition, {Duration timeout = const Duration(seconds: 20)})`: on timeout, `fail` with `what` and the last 20 lines of `mpvLog`.
- Clips, written by `run-tests.sh` into a temp dir with `ffmpeg` before the build: `e2e_sdr.mp4` (`testsrc2`, 1280x720, 24 fps, 10 s, libx264 yuv420p, sine audio) and `e2e_subs.mkv` (the same video with one SRT cue, 0 to 10 s, text `Mydia playback subtitle check`, language `eng`). `--dart-define=MYDIA_E2E_CLIPS=<dir>` joins `dart_defines`.

- [ ] **Step 1: Write the test file with two tests**

```dart
testWidgets('a local clip decodes and advances', (tester) async {
  final rig = await pumpPlayerScreen(tester, sdrClip);
  await waitFor(tester, 'time-pos past 2 s',
      () async => (double.tryParse(await rig.prop('time-pos')) ?? 0) > 2.0);
  expect(double.parse(await rig.prop('estimated-vf-fps')), greaterThan(0));
  await rig.close(tester);
});

testWidgets('Linux video renders on the hardware path', (tester) async {
  final rig = await pumpPlayerScreen(tester, sdrClip);
  await waitFor(tester, 'render path published',
      () async => (await rig.prop(renderPathProperty)).isNotEmpty);
  expect(await rig.prop(renderPathProperty), 'hw');
  await rig.close(tester);
}, skip: !Platform.isLinux ? 'render path is published on Linux only' : null);
```

`main()` starts with a fixture check modelled on `mac_surface_test.dart`: when `e2eClipsDir` is empty the group registers one skipped test with the reason; when it is set and a clip is missing it registers one test that `fail`s naming the missing path.

- [ ] **Step 2: Implement the rig, register the group, generate the clips, add ffmpeg to the client**

- [ ] **Step 3: `./dev flutter analyze` clean**

- [ ] **Step 4: Run `./dev player e2e` and settle unknown 1**

Expected: both tests pass. If the render test fails with `sw`, read the client log in the result for `media_kit: VideoOutput:` lines. If llvmpipe cannot reach the hardware branch at all, replace the property assertion with: the captured mpv/stderr log contains no `EGL display or context is invalid`, and say so in a comment on the test. Report which form was kept and the log lines that decided it.

- [ ] **Step 5: Prove the render assertion bites**

Temporarily restore upstream behaviour in `player/packages/media_kit_video/linux/video_output.cc` (the block marked `MYDIA PATCH` that resolves the display when no context is current), rerun `./dev player e2e`, confirm the render test fails, then `git checkout` the file. Report the failing output. Do not commit the revert.

- [ ] **Step 6: Prove a missing clip fails**

Rename one clip in a scratch edit of `run-tests.sh`, confirm the run fails naming the path, undo.

- [ ] **Step 7: Commit** `test(player): play a real clip in the Linux E2E and assert the render path`

### Task 2: Subtitle font, fullscreen and teardown on Linux

**Files:**
- Modify: `player/integration_test/playback_test.dart`
- Modify (only if unknown 2 requires): `scripts/e2e/run-tests.sh`, `nix/tests/player-e2e.nix`

**Interfaces:**
- Consumes: `pumpPlayerScreen`, `PlaybackRig`, `waitFor`, `subsClip`, `subtitleText` from Task 1; `kAppFontFamily` from `package:player/core/theme/app_theme.dart`.

- [ ] **Step 1: Add three tests**

1. `'a text subtitle draws in the app font'`: play `subsClip`, wait for a `Text` whose data contains `subtitleText`, resolve its effective style (`DefaultTextStyle.of(element).style.merge(text.style)`) and `expect(style.fontFamily, kAppFontFamily)`. If no subtitle track is selected by default, select the `eng` track through the rig's player first.
2. `'the fullscreen button enters and leaves fullscreen'`: tap the player's fullscreen control (find it by its key or tooltip in `lib/presentation/screens/player/`), wait for the native window to report fullscreen, tap the same control, wait for it to report windowed. Wire the fullscreen listener the way `mac_surface_test.dart`'s `setUpAll` does, with the Linux controller.
3. `'closing mid-playback disposes the player'`: wait for `time-pos` past 1 s, `rig.close(tester)`, then pump a trivial widget and `expect` it renders, proving the isolate and engine survived.

- [ ] **Step 2: Run `./dev player e2e` and settle unknown 2**

If fullscreen never takes under bare Xvfb, add `pkgs.openbox` to the client and start it inside the `xvfb-run` session before `flutter test` in `run-tests.sh` (wrap the command in `sh -c 'openbox & exec "$@"'`). Report whether it was needed.

- [ ] **Step 3: Prove the subtitle assertion bites**

Scratch-edit `player/lib/core/player/subtitle_size.dart` to drop `fontFamily: kAppFontFamily`, rerun, confirm red, undo.

- [ ] **Step 4: `./dev flutter analyze` clean, then commit** `test(player): subtitle font, fullscreen and teardown in the Linux playback E2E`

### Task 3: No vacuous pass in the existing playback E2E

**Files:**
- Modify: `player/integration_test/p2p_streaming_test.dart` (test `'Player can navigate to video and start playback'`, around line 548, and any other early `return` after a "Skipping" `debugPrint` in this file)

- [ ] **Step 1:** Replace each "Skipping ... return" branch with an `expect`/`fail` that names the missing precondition (`fileId` non-null, library rendered, the `E2E Test` movie found). Remove the "any movie in the grid" fallback: the seed guarantees `E2E Test Movie`.
- [ ] **Step 2:** `grep -n 'Skipping' player/integration_test/*.dart` returns nothing that precedes a `return`.
- [ ] **Step 3:** `./dev player e2e` green. If a now-strict precondition fails, that is a real defect the old test hid: fix the test's navigation or report it, do not restore the skip.
- [ ] **Step 4: Commit** `test(player): fail the playback E2E on a missing precondition`

### Task 4: Minimum passed-test guard

**Files:**
- Create: `scripts/ci/assert-test-count.sh`
- Create: `scripts/ci/assert-test-count-test.sh`
- Modify: `scripts/e2e/run-tests.sh`
- Modify: `.github/workflows/ci-nix.yml` (run the guard's own test next to `check-glass-diff-test.sh`)

**Interfaces:**
- Produces: `scripts/ci/assert-test-count.sh <reporter.json> <min-passed> [name-prefix]`. Input is the newline-delimited JSON of `flutter test --file-reporter json:<path>`. It counts `testDone` events with `result == "success"`, `hidden == false`, `skipped == false`, joined to their `testStart` name; with a prefix, only names starting with it. Exit 0 when count >= min. Exit 1 printing the count, the minimum and the skipped test names when below. Exit 1 when the file is missing, empty, or has no `done` event (a crashed run).

- [ ] **Step 1: Write `assert-test-count-test.sh`** with fixture JSON built inline for five cases: enough passes (exit 0), one skipped pushes it below (exit 1, names the skip), prefix filter counts only the prefix, missing file (exit 1), file with no `done` event (exit 1).
- [ ] **Step 2: Run it, expect failure** (guard not written).
- [ ] **Step 3: Implement the guard** with `jq -s`. Honour `set -e`: capture exit codes as `code=0; cmd || code=$?`.
- [ ] **Step 4: Run the test script, expect all five pass.**
- [ ] **Step 5: Wire into `run-tests.sh`:** add `--file-reporter json:<tmp>/e2e-report.json` to `flutter_cmd`; after the run, call the guard with prefix `playback ` and minimum `PLAYBACK_MIN_PASSED=5` defined at the top of the script with a comment that adding a playback test means raising it. The guard's failure sets a non-zero exit even when `flutter test` exited 0.
- [ ] **Step 6:** `./dev player e2e` green; then mark one playback test `skip: 'guard check'`, rerun, confirm red from the guard, undo.
- [ ] **Step 7: Commit** `ci(player): fail the E2E when fewer playback tests pass than pinned`

### Task 5: macOS integration job

**Files:**
- Modify: `player/integration_test/mac_surface_test.dart`
- Modify: `.github/workflows/ci-player.yml`

**Interfaces:**
- Consumes: `scripts/ci/assert-test-count.sh` from Task 4.

Nothing in this task can be executed on Linux. Verify what can be (`./dev flutter analyze`, `actionlint` on the workflow via `nix shell nixpkgs#actionlint`), and report the rest as unverified until the job runs on GitHub.

- [ ] **Step 1: Capability check in `mac_surface_test.dart`.** Add `Future<bool> _hdrDisplay()` that is true when a display reports EDR headroom (use what `MpvSurfaceChannel` or `screen_retriever` already exposes; if neither does, read `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1` through a new method on the existing `mydia/mpv-surface` channel in `player/macos/Runner/MpvSurface/MpvSurfacePlugin.swift`). The test `'HDR10 plays through gpu-next with PQ output'` calls `markTestSkipped('no HDR display')` and returns when it is false. `_moveToBuiltIn` falls back to the primary display when no built-in panel exists and returns its name. `_missingFixtures` keeps requiring all three clips: the job generates them.
- [ ] **Step 2: Add job `integration-macos`, name `Integration / macOS`,** `runs-on: xcode-27`, `timeout-minutes: 45`, with the same checkout, Flutter setup, pub cache, `pub get --enforce-lockfile` and codegen steps as the `build` job. Then:
  1. Cache `~/mydia-hdr/fixtures` keyed on `hashFiles('scripts/generate-hdr-fixtures.sh')`.
  2. On a miss, `brew install ffmpeg` is not assumed to have zscale/libx265; run `scripts/generate-hdr-fixtures.sh ~/mydia-hdr/fixtures` (it re-execs under nix when tools are missing, so install Nix with `DeterminateSystems/nix-installer-action` before it), then mux `sdr_subs.mkv` exactly as `player/docs/playback.md` shows.
  3. `caffeinate -d` in the background for the test step.
  4. `flutter test integration_test/mac_surface_test.dart -d macos --dart-define=MYDIA_HDR_FIXTURES=$HOME/mydia-hdr/fixtures --file-reporter json:$RUNNER_TEMP/mac-report.json`
  5. `scripts/ci/assert-test-count.sh $RUNNER_TEMP/mac-report.json 8`: the nine `testWidgets` minus the HDR case. Recount from the file and pin the real number.
  6. `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'` in `player/`.
  7. Upload the report and the app's log as an artifact on failure.
- [ ] **Step 3:** `actionlint .github/workflows/ci-player.yml` clean, `./dev flutter analyze` clean.
- [ ] **Step 4: Commit** `ci(player): run the macOS surface and Runner tests on every player PR`

### Task 6: Docs and spec

**Files:**
- Modify: `player/docs/testing.md` (new section: the Linux playback test, the local-clip rig, the count guard and how to raise the minimum)
- Modify: `player/docs/playback.md` ("It runs on a Mac only and is not part of CI" becomes where it runs in CI and what skips there)
- Modify: `.github/ci.md` (the `ci-player.yml` section lists `Integration / macOS`)
- Modify: `design/specs/2026-11-28-player-ci-real-playback-design.md` (Linux section: local clip, not the seeded movie; record how each unknown resolved)

- [ ] **Step 1:** Write the four edits from what Tasks 1 to 5 actually did, including which fallbacks were taken.
- [ ] **Step 2: Commit** `docs(player): real-playback CI on Linux and macOS`

### Task 7: Prove the macOS job on GitHub (unknown 3)

- [ ] **Step 1:** Push the branch with an explicit refspec and run `gh workflow run ci-player.yml --ref <branch>`.
- [ ] **Step 2:** Watch `Integration / macOS`. Fix what fails. If fullscreen cannot run on the runner, skip that one case with a logged reason, lower the pinned minimum by one, and record it in the spec. If the display link never fires and no playback case can run, reduce the job to `RunnerTests`, and record in the spec what was lost.
- [ ] **Step 3:** Report the final job URL and its list of run and skipped tests.
