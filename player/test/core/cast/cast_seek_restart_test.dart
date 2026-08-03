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
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_seek_restart.dart';

void main() {
  test('a small forward skip seeks in place', () {
    expect(
      shouldRestartCastForSeek(
        mediaKind: CastMediaKind.hls,
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
        mediaKind: CastMediaKind.hls,
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
        mediaKind: CastMediaKind.hls,
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
        mediaKind: CastMediaKind.hls,
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
        mediaKind: CastMediaKind.hls,
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
        mediaKind: CastMediaKind.hls,
        target: const Duration(seconds: 3600),
        currentPosition: Duration.zero,
        startOffset: Duration.zero,
      ),
      isTrue,
    );
  });

  test('a target exactly at the start offset seeks in place', () {
    // The offset is the first position the stream actually contains, so it is
    // reachable. The predicate's first clause is deliberately strict
    // (`target < startOffset`) for this reason.
    expect(
      shouldRestartCastForSeek(
        mediaKind: CastMediaKind.hls,
        target: const Duration(seconds: 2394),
        currentPosition: const Duration(seconds: 2400),
        startOffset: const Duration(seconds: 2394),
      ),
      isFalse,
    );
  });

  group('progressive routes', () {
    // A DLNA renderer gets a byte-range stream of the whole file: the offset
    // is always zero, every position is addressable, and a receiver seek is
    // valid anywhere. Restarting there tears down a session for a target it
    // could already reach.
    test('never restart, however far forward the target is', () {
      expect(
        shouldRestartCastForSeek(
          mediaKind: CastMediaKind.progressive,
          target: const Duration(seconds: 5400),
          currentPosition: Duration.zero,
          startOffset: Duration.zero,
        ),
        isFalse,
        reason: 'a progressive receiver can seek anywhere in the file',
      );
    });

    test('never restart even for a target before the offset', () {
      // Defensive: a progressive route should never carry a non-zero offset in
      // the first place, but the media kind alone must settle the decision.
      expect(
        shouldRestartCastForSeek(
          mediaKind: CastMediaKind.progressive,
          target: const Duration(seconds: 60),
          currentPosition: const Duration(seconds: 2400),
          startOffset: const Duration(seconds: 2394),
        ),
        isFalse,
      );
    });

    test('the identical HLS case does restart', () {
      // The control for the two above: same numbers, different media kind.
      // Without it, those tests would pass even if the predicate had simply
      // stopped restarting altogether.
      expect(
        shouldRestartCastForSeek(
          mediaKind: CastMediaKind.hls,
          target: const Duration(seconds: 5400),
          currentPosition: Duration.zero,
          startOffset: Duration.zero,
        ),
        isTrue,
      );
    });
  });
}
