// Seeking a cast is broken by the same root cause as resuming one: the
// receiver holds a live-style HLS playlist covering only what FFmpeg has
// written, so a target beyond it cannot be reached and the receiver clamps,
// which reads to the user as a snap back.
//
// The local predicate `shouldRestartForSeek` cannot be reused: it needs
// `seekableEnd` from the player's own raw duration, and a Chromecast reports
// -1 for these playlists forever, so the transcoded extent is not observable
// from the receiver at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_seek_restart.dart';

void main() {
  test('a small forward skip seeks in place', () {
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 2410),
        currentPosition: const Duration(seconds: 2400),
        startOffset: const Duration(seconds: 2394),
      ),
      isFalse,
    );
  });

  test('a skip exactly at the tolerance seeks in place', () {
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 2430),
        currentPosition: const Duration(seconds: 2400),
        startOffset: Duration.zero,
      ),
      isFalse,
    );
  });

  test('a large forward scrub restarts', () {
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 3000),
        currentPosition: const Duration(seconds: 2400),
        startOffset: const Duration(seconds: 2394),
      ),
      isTrue,
    );
  });

  test('a target before the start offset restarts', () {
    // Not present in this stream at all: the session begins at 2394s, so
    // minute five simply is not in the playlist.
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 300),
        currentPosition: const Duration(seconds: 2400),
        startOffset: const Duration(seconds: 2394),
      ),
      isTrue,
    );
  });

  test('a backward seek inside the window seeks in place', () {
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 2500),
        currentPosition: const Duration(seconds: 2600),
        startOffset: const Duration(seconds: 2394),
      ),
      isFalse,
    );
  });

  test('a zero-offset session still restarts on a long forward scrub', () {
    expect(
      shouldRestartCastForSeek(
        target: const Duration(seconds: 3600),
        currentPosition: Duration.zero,
        startOffset: Duration.zero,
      ),
      isTrue,
    );
  });
}
