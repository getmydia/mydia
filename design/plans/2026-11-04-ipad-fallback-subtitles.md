# iOS decode detection and subtitles across fallback: implementation plan

Spec: `design/specs/2026-11-04-ipad-fallback-subtitles-design.md`. Read it
first; it holds the log evidence, the causes and the decisions. This plan only
orders the work.

## Global Constraints

- All work is in `player/` (Flutter) plus one Swift file under
  `player/ios/Runner/`. No server, relay or GraphQL changes.
- Run Flutter commands through the wrapper: `./dev flutter test <path>` and
  `./dev flutter analyze`. Both must pass for touched files before committing.
- Commit with `git add <paths>` then `git commit -F <msgfile>` from inside the
  devenv environment (`direnv exec . git commit -F <msgfile>`), and verify with
  `git show --stat HEAD`. Never `--no-verify`. Commit email is
  `arsfeld@gmail.com` (already configured). No AI attribution in messages.
- Conventional commit subjects, `player` scope, e.g.
  `fix(player): carry a preference-applied subtitle across a source switch`.
- No em dashes in code comments, docs or commit messages.
- Never real movie or TV titles in tests or fixtures; invent them.
- Follow the existing style: decisions that are pure functions live in
  `subtitle_track_builder.dart` / `subtitle_preference.dart` and get unit
  tests; `player_screen.dart` wires them. Comments explain why, at the density
  of the surrounding code.
- Tests first: each behaviour change starts with a test that fails on the
  current code.

## Task 1: Carry a preference-applied subtitle across a source switch

Spec section: "Design / 1. Carry a preference-applied subtitle across a
switch", plus "Causes 3" and the Part 1 bullets under "Testing".

1. Write a player-screen widget test reproducing the iPad sequence (model it
   on `player/test/presentation/screens/player/player_screen_source_switch_test.dart`
   and `subtitle_preference_apply_test.dart`): native direct play; a saved
   subtitle preference that resolves to a server-delivered track; the apply
   fetches it and `sub-add`s it, after which the fake player's track list
   gains one extra mpv entry for the added file and reports it as current; a
   `decodeTooSlow` fallback to transcode; the new source's track list arrives.
   Assert the same server track ends selected on the transcode, it was
   re-applied to the player, and no `notCarried` toast was shown. Run it on
   the current code and record in the report which step drops the choice.
2. Fix so the test passes, per the spec:
   - a revision after a `sub-add` keeps the selection on the server track, and
     the added file's mpv entry is not offered as a separate subtitle row;
   - when a switch captures no explicit intent and the selection came from the
     preference, the preference is carried and re-applied on the new source;
   - a carried choice that cannot be applied shows `subtitleNoticeNotCarried`.
3. Add the second test from the spec: a carried preference that matches
   nothing on the new source shows `notCarried`.
4. Run the subtitle and source-switch test files under
   `player/test/presentation/screens/player/` plus any unit tests for the pure
   functions you change; all must pass. Commit.

## Task 2: An embedded preference waits for mpv in direct play

Spec section: "Design / 2. An embedded preference waits for mpv in direct
play", plus the Part 2 bullets under "Testing". Builds on Task 1's changes to
`_applySubtitlePreference` and `shouldApplySubtitlePreference`.

1. Tests first (widget tests alongside `subtitle_preference_apply_test.dart`):
   - the 3 s track cap expires before mpv reports any subtitle track, the
     preference resolves to an embedded server track: no server subtitle fetch
     happens, and once mpv publishes its list the preference applies from
     mpv's own track;
   - mpv never reports tracks: the server fetch happens after the backstop,
     5 s after the first frame;
   - a sidecar (non-embedded) preference still applies when the cap expires.
2. Implement. Keep the decision a pure function with unit tests where
   practical (extend `shouldApplySubtitlePreference` or add a sibling), and
   keep the backstop duration a named constant.
3. Run the subtitle preference and subtitle loading test files; all must
   pass. Commit.

## Task 3: iOS hardware decode detection

Spec section: "Design / 3. iOS hardware decode detection", plus the Part 3
bullets under "Testing".

1. Dart side, tests first: a new probe (sibling of
   `player/lib/core/player/android_codec_capabilities.dart`, e.g.
   `ios_codec_capabilities.dart`) calling method `hardwareVideoDecoders` on
   the existing `dev.mydia.player/codecs` channel, returning which of hevc,
   vp9, av1 have hardware decode. `detectDeviceProfile` in
   `device_profile_native.dart` applies it on iOS only, removing every alias
   of an unsupported codec from `videoCodecs` (hevc: `hevc`, `h265`, `h.265`,
   `hvc1`; vp9: `vp9`, `vp09`; av1: `av1`, `av01`), and logs
   `[DeviceProfile] ios hardware decode: hevc=<bool> vp9=<bool> av1=<bool>`.
   A failed, empty or missing-plugin probe leaves the profile unchanged. Make
   the platform check injectable so tests can cover iOS and non-iOS. Tests
   with a fake channel, modelled on `android_codec_capabilities_test.dart`.
2. Swift side: a handler for `dev.mydia.player/codecs` registered in
   `player/ios/Runner/AppDelegate.swift` (follow how the other channels there
   are registered), answering `hardwareVideoDecoders` with
   `{"hevc": Bool, "vp9": Bool, "av1": Bool}` from
   `VTIsHardwareDecodeSupported`. VP9 needs iOS 14 and AV1 iOS 17 for
   `kCMVideoCodecType_VP9` / `kCMVideoCodecType_AV1`; below that report false.
   Unknown methods return `FlutterMethodNotImplemented`. If an iOS build is not
   possible on this Linux host, say so in the report; do not fake it.
3. Run the device profile and codec test files plus `./dev flutter analyze`.
   Commit.
