# Player CI: real playback on Linux and macOS

## Goal

A dependency or SDK bump that leaves the player running but behaving wrong
turns its pull request red. Today only a person notices.

## Context

Flutter 3.50.1 (#1486), a dependency group bump and the `material_ui`
migration landed between 2026-11-21 and 2026-11-23. Six regressions followed.
CI caught one, the crash at launch. The other five ran fine and behaved wrong:

| Regression | Fix | Platform |
| --- | --- | --- |
| Video rendered on the CPU: stutter, 1080p cap | `d21bb3683` | Linux |
| Text subtitles in Roboto, not the app font | `f0c053655` | texture path |
| Fullscreen state, geometry restore, window sizing dead | `fa898838b` | macOS |
| Fullscreen button could not exit | `5095c4fa8` | Windows |
| 225 ms blank content area on a rail switch | `e980a7ac4` | all |

Why the gate missed them:

- The unit and widget suite (941 files) runs headless against fakes.
- `player-e2e` (`nix/tests/player-e2e.nix`) runs the real app under Xvfb, but
  its playback is scripted state. `p2p_streaming_test.dart` has a test named
  "Player can navigate to video and start playback" that returns early, and
  passes, when the media or the library UI is missing. It never asserts a
  frame or a position.
- The Flatpak and AppImage smoke tests assert that the app survives ten
  seconds.
- `integration_test/mac_surface_test.dart` and `macos/RunnerTests` cover real
  playback, subtitles and fullscreen on macOS. No workflow runs either.

## Shape

One addition that runs real video, and one that does not. Both run on every
pull request that touches `player/**`. One PR.

1. Linux: a real-playback test file inside the existing `player-e2e` VM test.
   Blocking, through `Test / Player E2E`.
2. macOS: an `Integration / macOS` job in `ci-player.yml` that runs
   `RunnerTests`. Not a required context, and it plays no video (see below).

Windows, Android, iOS and screenshot goldens are out of scope. Goldens were
considered for the two visual escapes and rejected: pixel output differs
between llvmpipe, Metal and engine versions, so every Flutter bump would need
a re-baseline at the moment the test most needs to be trusted.

## Linux: `integration_test/playback_test.dart`

A new file, added to `all_tests.dart` as the `playback` group. It mounts the
real `PlayerScreen` on a real media_kit `Player` and reads mpv's own
properties. It does not pair or use the server's seeded movie: the clips are
generated on the VM client by `scripts/e2e/run-tests.sh` (a 10 s 1280x720
`testsrc2` mp4, and the same video with one English SRT cue muxed in) and
reach the test as `--dart-define=MYDIA_E2E_CLIPS`. The rig is
`integration_test/helpers/playback_rig.dart`.

Seven tests:

| Test | Escape it would have caught |
| --- | --- |
| A local clip decodes and advances (`time-pos` passes 2 s, `estimated-vf-fps` above zero) | frames not decoded |
| The Linux video output does not hit the EGL display failure | CPU rendering after Flutter 3.50 |
| A text subtitle draws with `kAppFontFamily` | Roboto subtitles |
| The fullscreen button enters fullscreen and the same button leaves it | fullscreen exit |
| Closing mid-playback disposes the player and the app keeps responding | quit and teardown crashes |
| Closing right after opening, five times, leaves the app responsive | a GTK-thread deadlock found while building the suite |
| The stats sampler reports the Linux render path | the stats panel missing software rendering |

The render assertion is the weaker form. Under llvmpipe the hardware path is
unreachable, so the test asserts that media_kit never logs `EGL display or
context is invalid` (captured from the process's native stderr) and that the
output logged at all. It does not prove hardware rendering, and a regression
later in the hardware path would not be caught.

Fullscreen needs a window manager: the VM client runs `openbox` inside
`xvfb-run`, on a 1920x1080 screen. A watchdog in `run-tests.sh` prints the
app's native stacks with gdb and kills it if the suite outlives 600 s, since a
frozen GTK thread stops every Dart timer. Every pump in the file goes through
a bounded helper (`pumpBounded`) that works around a flutter_test frame-stall
race, and every wait has a deadline.

Every precondition is an `expect` or `fail`. A missing clip, or a player that
never mounts, fails the test. The early `return`s in the old "Player can
navigate to video and start playback" test are gone: it now taps through to
the player screen and back, and asserts each step.

## macOS: `Integration / macOS` in `ci-player.yml`

The spec planned to run `mac_surface_test.dart` and `RunnerTests`. GitHub's
hosted macOS runner is a virtual machine whose only GPU is Apple's paravirtual
device, and both video outputs kill the app on it: gpu-next segfaults in
MoltenVK on its first texture upload, and media_kit's texture path traps in
the OpenGL pixel format helper. So the job runs `RunnerTests` through
`xcodebuild test` and nothing else, on the same image and Xcode as the macOS
build leg.

`mac_surface_test.dart` is not run in CI. It stays a test to run on a Mac, and
it now skips every case on a paravirtual GPU (and the HDR10 case on a screen
with no EDR headroom). No CI job covers macOS playback.

## No silent passes

A skipped test reads as green, which is how the old playback test hid. The
Linux run writes the reporter's JSON and `scripts/ci/assert-test-count.sh`
fails the run when fewer than `PLAYBACK_MIN_PASSED` (7, in `run-tests.sh`)
tests named `playback *` passed, or when the report is missing or has no
`done` event. Raising the count is part of adding a test. The guard has its
own test, `scripts/ci/assert-test-count-test.sh`. There is no counterpart on
macOS, since no playback test runs there.

## How the unknowns resolved

1. **Does llvmpipe EGL in the VM reach media_kit's hardware branch?** No. The
   patched output passes the display check, then fails `eglMakeCurrent` on its
   surfaceless context and publishes `sw`. The fallback assertion is used.
2. **Does fullscreen work under Xvfb with no window manager?** No. `openbox`
   is added, and the Xvfb screen is 1920x1080.
3. **Can a hosted macOS runner play video?** No. The job is reduced to
   `RunnerTests`, as this spec said it would be if the display link never
   fired.

## Found along the way

The new tests found four defects, fixed in the same PR:

- The stats panel never reported software rendering: mpv returns the render
  path JSON-quoted (`"sw"`) and the sampler matched only the bare word.
- A deadlock in the vendored `media_kit_video` on Linux: a software redraw
  queued on the GTK thread with a bare pointer could run after the output was
  freed when a player closed right after opening (`MYDIA_PATCHES.md`).
- The player chrome notified a listener during a build.
- The old "Player can navigate to video and start playback" E2E test had never
  reached the player.

## Not covered

- The hardware render path on Linux.
- All macOS playback.
- Windows, Android and iOS.

## Flakes

Blocking from the first merge. A test that proves flaky is fixed or removed
within the same week, and gets an entry in `.github/ci-flakes.md`. It is never
wrapped in a retry.

## Verification

- `./dev player e2e` green locally with the new file.
- Each Linux assertion shown to fail on the commit before its fix.
- The count guard shown to fail when a test is skipped.

## Docs

`player/docs/testing.md` describes the Linux playback test and the count
guard. `player/docs/playback.md` says why the macOS test is not in CI.
`.github/ci.md` describes the `Integration / macOS` job.
