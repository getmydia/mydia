// Unit coverage for `shouldRestartForSeek`, the pure boolean extracted from
// `_PlayerScreenState.seekToReal`'s own restart-vs-local-seek decision.
//
// Extracted (rather than tested through a fully mounted `PlayerScreen`)
// because reaching a non-null `_player` in `flutter test` would require a
// real, native-backed media_kit `Player` — `NativePlayer`'s constructor
// calls `DynamicLibrary.open` synchronously, which needs real mpv/FFI that
// is not available under `flutter test`. Every existing test in this suite
// that needs a `Player` injects a fake `platformPlayer` for exactly this
// reason (see `gesture_chrome_composition_test.dart` and
// `playback_chrome_episode_nav_test.dart`), and `PlayerScreen` itself always
// constructs a bare `Player()` with no way to substitute a fake — so
// `seekToReal`'s dispatch into a live player can only ever be a no-op
// (`if (player == null) return;`) inside this test suite. This file instead
// pins down the actual restart/no-restart boundary — the part of the logic
// most likely to regress — directly and deterministically.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('shouldRestartForSeek', () {
    test('an in-range seek within the transcoded window stays local', () {
      // A session resumed at 10 minutes in (startOffset = 600s), with the
      // playlist transcoded up to local position 300s (real 900s) so far.
      // Seeking to real 620s (local 20s) is well within both bounds.
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 620),
          localTarget: const Duration(seconds: 20),
          seekableEnd: const Duration(seconds: 300),
          startOffset: const Duration(seconds: 600),
        ),
        isFalse,
      );
    });

    test('a seek past what has been transcoded so far restarts the session',
        () {
      // Same session as above, but the user scrubs to local 400s — beyond
      // the 300s the playlist currently covers.
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 1000),
          localTarget: const Duration(seconds: 400),
          seekableEnd: const Duration(seconds: 300),
          startOffset: const Duration(seconds: 600),
        ),
        isTrue,
      );
    });

    test(
        'a seek before the session start offset restarts the session even '
        'when the local target looks in range', () {
      // Scrubbing to real 500s when the session only covers from 600s
      // onward: not present in this stream at all, regardless of how
      // `toPlayer` clamped the local target.
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 500),
          localTarget: Duration.zero,
          seekableEnd: const Duration(seconds: 300),
          startOffset: const Duration(seconds: 600),
        ),
        isTrue,
      );
    });

    test(
        'direct play never restarts, even when the raw numbers would look '
        'out of range', () {
      // Direct play/offline hold the whole file locally; there is no HLS
      // session to restart, whatever `seekableEnd`/`startOffset` say.
      expect(
        shouldRestartForSeek(
          isDirectPlay: true,
          realTarget: const Duration(seconds: 9999),
          localTarget: const Duration(seconds: 9999),
          seekableEnd: const Duration(seconds: 10),
          startOffset: const Duration(seconds: 600),
        ),
        isFalse,
      );
    });

    test('a target exactly at the transcoded boundary stays local', () {
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 900),
          localTarget: const Duration(seconds: 300),
          seekableEnd: const Duration(seconds: 300),
          startOffset: const Duration(seconds: 600),
        ),
        isFalse,
      );
    });

    test('a target exactly at the start offset stays local', () {
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 600),
          localTarget: Duration.zero,
          seekableEnd: const Duration(seconds: 300),
          startOffset: const Duration(seconds: 600),
        ),
        isFalse,
      );
    });

    test(
        'an out-of-range seek restarts even for a zero-offset session '
        '(no resume in play)', () {
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 400),
          localTarget: const Duration(seconds: 400),
          seekableEnd: const Duration(seconds: 300),
          startOffset: Duration.zero,
        ),
        isTrue,
      );
    });

    test('an in-range seek stays local for a zero-offset session', () {
      expect(
        shouldRestartForSeek(
          isDirectPlay: false,
          realTarget: const Duration(seconds: 200),
          localTarget: const Duration(seconds: 200),
          seekableEnd: const Duration(seconds: 300),
          startOffset: Duration.zero,
        ),
        isFalse,
      );
    });
  });
}
