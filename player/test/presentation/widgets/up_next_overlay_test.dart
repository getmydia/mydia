import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/presentation/widgets/up_next_overlay.dart';

void main() {
  group('shouldOfferUpNext', () {
    const duration = Duration(minutes: 45);
    const credits = MediaSegment(
      type: SegmentType.credits,
      startMs: 2640000, // 44:00
      endMs: 2700000, // 45:00
    );

    test('is false before credits start, even in the old 90% window', () {
      // 40:30 into a 45-minute episode: past the old 90% threshold
      // (40:30 = 90% of 45:00) but two and a half minutes before the
      // detected credits actually begin.
      expect(
        shouldOfferUpNext(
          segments: [credits],
          position: const Duration(minutes: 40, seconds: 30),
          duration: duration,
        ),
        isFalse,
      );
    });

    test('is true once playback reaches the credits segment', () {
      expect(
        shouldOfferUpNext(
          segments: [credits],
          position: const Duration(minutes: 44),
          duration: duration,
        ),
        isTrue,
      );
    });

    test('is true past the credits start even outside the fallback window', () {
      // A credits segment is authoritative regardless of how far from the
      // real end it sits.
      const earlyCredits = MediaSegment(
        type: SegmentType.credits,
        startMs: 600000, // 10:00
        endMs: 660000, // 11:00
      );
      expect(
        shouldOfferUpNext(
          segments: [earlyCredits],
          position: const Duration(minutes: 10, seconds: 30),
          duration: duration,
        ),
        isTrue,
      );
    });

    group('fallback window (no credits segment detected)', () {
      test('is false outside the last 60 seconds', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: const Duration(minutes: 43, seconds: 59),
            duration: duration,
          ),
          isFalse,
        );
      });

      test('is true within the last 60 seconds', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: const Duration(minutes: 44),
            duration: duration,
          ),
          isTrue,
        );
      });

      test('is false for zero duration', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: Duration.zero,
            duration: Duration.zero,
          ),
          isFalse,
        );
      });
    });

    test('ignores a non-credits segment (e.g. intro) for the fallback', () {
      const intro = MediaSegment(
        type: SegmentType.intro,
        startMs: 0,
        endMs: 60000,
      );

      expect(
        shouldOfferUpNext(
          segments: [intro],
          position: const Duration(minutes: 44),
          duration: duration,
        ),
        isTrue,
        reason: 'no credits segment was detected, so the fallback window '
            'still applies',
      );
      expect(
        shouldOfferUpNext(
          segments: [intro],
          position: const Duration(minutes: 40),
          duration: duration,
        ),
        isFalse,
        reason: '40:00 is outside the fallback window on a 45-minute '
            'episode, unlike the old 90% heuristic',
      );
    });
  });
}
