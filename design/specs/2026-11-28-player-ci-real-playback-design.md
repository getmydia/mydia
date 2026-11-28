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

Two additions, both on every pull request that touches `player/**`, both
blocking. One PR.

1. Linux: a real-playback test file inside the existing `player-e2e` VM test.
2. macOS: a new job in `ci-player.yml` that runs `mac_surface_test.dart` and
   `RunnerTests`.

Windows, Android, iOS and screenshot goldens are out of scope. Goldens were
considered for the two visual escapes and rejected: pixel output differs
between llvmpipe, Metal and engine versions, so every Flutter bump would need
a re-baseline at the moment the test most needs to be trusted.

## Linux: `integration_test/playback_test.dart`

A new file, added to `all_tests.dart` as the `playback` group. It pairs, opens
the seeded movie (`/media/movies/e2e-test-video.mp4`, 5 s of `testsrc2`
written by `scripts/e2e/seed.sh`) through the real `PlayerScreen`, and reads
mpv's own properties from the live `Player`.

| Assertion | Escape it would have caught |
| --- | --- |
| `time-pos` passes 2 s and `estimated-vf-fps` is above zero | none yet; proves frames are decoded |
| `user-data/media-kit/render` (`renderPathProperty`) reports the hardware path, and the client log has no `S/W rendering` line | CPU rendering |
| A text subtitle is on screen and its resolved `fontFamily` is `kAppFontFamily` | Roboto subtitles |
| The fullscreen button enters fullscreen and the same button leaves it | fullscreen exit |
| Closing the player mid-playback disposes it and the app keeps running | quit and teardown crashes |

The seed gains a second clip with a muxed SRT track for the subtitle
assertion, built the way `player/docs/playback.md` builds `sdr_subs.mkv`.

Every precondition is an `expect`. A missing movie, an empty library or a
player that never mounts fails the test. The early `return`s in the existing
"Player can navigate to video and start playback" test are removed, and that
test is deleted if the new file covers all of it.

The test waits on conditions with a timeout (the `_pumpUntil` pattern in
`mac_surface_test.dart`), never on fixed sleeps.

## macOS: `Integration / macOS` in `ci-player.yml`

A new job on the same runner image and Xcode as the existing macOS build.

1. Generate fixtures with `scripts/generate-hdr-fixtures.sh`, then mux
   `sdr_subs.mkv` as `player/docs/playback.md` describes. Cache the output
   keyed on the script's hash.
2. `flutter test integration_test/mac_surface_test.dart -d macos
   --dart-define=MYDIA_HDR_FIXTURES=<dir>`. With the define set, a missing
   clip fails the run.
3. `xcodebuild test` on the `Runner` scheme for `RunnerTests`.

A hosted runner has no HDR display and no built-in panel.
`mac_surface_test.dart` gets one explicit capability check: the HDR10 and PQ
cases skip with a logged reason when no display reports EDR headroom, and
`_moveToBuiltIn` falls back to the main display. SDR playback, fill, text
subtitles, fullscreen, close mid-playback, the source switch and the open and
close cycles must run.

## No silent passes

A skipped test reads as green, which is how the existing playback test hid.
Both jobs parse the reporter's JSON output and fail when the number of tests
that ran and passed is below a minimum pinned next to the job: all of the
`playback` group on Linux, and every non-HDR case on macOS. Raising the count
is part of adding a test.

## Unknowns, probed before the rest

Each is the first task of its half. The fallback is decided here so a negative
result does not reopen the design.

1. **Does llvmpipe EGL in the VM reach media_kit's hardware branch?** KVM is
   available on the dev machine, so this is settled locally. If it does not,
   the render assertion becomes "the log has no `EGL display or context is
   invalid` line", which is the exact failure 3.50 introduced.
2. **Does fullscreen work under Xvfb with no window manager?** If it does
   not, the VM client starts a minimal one (`openbox`) inside `xvfb-run`.
3. **Does a hosted macOS runner give the test a window session that can
   enter fullscreen and keep a display link alive?** Settled by the first
   push of the job. If fullscreen cannot run there, that case stays local and
   the window behaviour is covered by `WindowPluginTests` in `RunnerTests`.
   If the display link never fires, the macOS job reduces to `RunnerTests`
   and the spec is updated to say what was lost.

## Flakes

Blocking from the first merge. A test that proves flaky is fixed or removed
within the same week, and gets an entry in `.github/ci-flakes.md`. It is never
wrapped in a retry.

## Verification

- `./dev player e2e` green locally with the new file.
- Each Linux assertion shown to fail on the commit before its fix: revert
  `d21bb3683` and `f0c053655` in a scratch branch and confirm red.
- The macOS job green on the PR, and its log lists every non-HDR case as run.
- The minimum-count guard shown to fail when one test is marked `skip`.

## Docs

`player/docs/testing.md` gains the Linux playback test and the count guard.
`player/docs/playback.md` drops "is not part of CI" for the macOS test.
`.github/ci.md` lists the new job.
