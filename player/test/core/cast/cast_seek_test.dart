import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_seek.dart';

/// What a Chromecast reports for a stream whose length it cannot work out.
/// Every case below that uses it is a regression test for the bug where the
/// scrub bar and the skip-ahead button both seeked to the start of the video.
const unknown = Duration(seconds: -1);

void main() {
  group('hasKnownDuration', () {
    test('rejects the Chromecast -1 placeholder', () {
      expect(hasKnownDuration(unknown), isFalse);
    });

    test('rejects zero, which is the pre-first-status placeholder', () {
      expect(hasKnownDuration(Duration.zero), isFalse);
    });

    test('accepts a real runtime', () {
      expect(hasKnownDuration(const Duration(minutes: 107)), isTrue);
    });
  });

  group('seekTargetForFraction', () {
    test('returns null instead of zero when the duration is unknown', () {
      expect(seekTargetForFraction(0.5, unknown), isNull);
    });

    test('returns null when the duration is zero', () {
      expect(seekTargetForFraction(0.5, Duration.zero), isNull);
    });

    test('maps a fraction onto a known duration', () {
      expect(
        seekTargetForFraction(0.25, const Duration(minutes: 100)),
        const Duration(minutes: 25),
      );
    });

    test('clamps out-of-range fractions', () {
      const duration = Duration(minutes: 100);
      expect(seekTargetForFraction(-0.5, duration), Duration.zero);
      expect(seekTargetForFraction(1.5, duration), duration);
    });
  });

  group('clampSeekTarget', () {
    test('does not clamp a forward skip against an unknown duration', () {
      // The bug: `target > duration` was true for every position because
      // duration was -1s, so every skip-ahead collapsed to the start.
      expect(
        clampSeekTarget(const Duration(minutes: 12), unknown),
        const Duration(minutes: 12),
      );
    });

    test('clamps a forward skip to a known duration', () {
      expect(
        clampSeekTarget(const Duration(minutes: 120), const Duration(hours: 1)),
        const Duration(hours: 1),
      );
    });

    test('floors a rewind at zero', () {
      expect(
          clampSeekTarget(const Duration(seconds: -5), unknown), Duration.zero);
      expect(
        clampSeekTarget(const Duration(seconds: -5), const Duration(hours: 1)),
        Duration.zero,
      );
    });

    test('leaves an in-range target alone', () {
      expect(
        clampSeekTarget(const Duration(minutes: 30), const Duration(hours: 1)),
        const Duration(minutes: 30),
      );
    });
  });

  group('castProgressFraction', () {
    test('is zero when the duration is unknown', () {
      expect(castProgressFraction(const Duration(minutes: 5), unknown), 0.0);
    });

    test('reports progress through a known duration', () {
      expect(
        castProgressFraction(
            const Duration(minutes: 30), const Duration(hours: 1)),
        0.5,
      );
    });

    test('clamps past-the-end positions', () {
      expect(
        castProgressFraction(
            const Duration(hours: 2), const Duration(hours: 1)),
        1.0,
      );
    });
  });
}
