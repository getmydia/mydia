import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/player/stream_timeline.dart';

void main() {
  group('ProgressService.resolveSync', () {
    test(
        'uses the authoritative server duration, not the partial HLS duration '
        '(regression: a few seconds must not read as ~30%)', () {
      const timeline = StreamTimeline(totalDuration: Duration(seconds: 3452));

      final progress = ProgressService.resolveSync(
        const Duration(seconds: 12), // a few seconds watched
        const Duration(seconds: 40), // partial transcoded length so far
        timeline,
      );

      expect(progress, isNotNull);
      // Without the fix, duration would be 40 → 12/40 = 30% (inflated).
      expect(progress!.durationSeconds, 3452);
      expect(progress.positionSeconds, 12);
      expect(
          progress.positionSeconds / progress.durationSeconds, lessThan(0.01));
    });

    test('falls back to the player duration when the server said nothing', () {
      final progress = ProgressService.resolveSync(
        const Duration(seconds: 600),
        const Duration(seconds: 3452),
        StreamTimeline.zero,
      );

      expect(progress, isNotNull);
      expect(progress!.durationSeconds, 3452);
      expect(progress.positionSeconds, 600);
    });

    test('reports positions in real media time when the stream is offset', () {
      // Resumed at 01:00:00, so the player's own position 0 is really 3600s in.
      const timeline = StreamTimeline(
        startOffset: Duration(seconds: 3600),
        totalDuration: Duration(seconds: 5400),
      );

      final progress = ProgressService.resolveSync(
        const Duration(seconds: 120), // two minutes into the offset stream
        const Duration(seconds: 1800),
        timeline,
      );

      expect(progress, isNotNull);
      expect(progress!.positionSeconds, 3720);
      expect(progress.durationSeconds, 5400);
    });

    test('returns null when duration is unknown (still loading)', () {
      expect(
        ProgressService.resolveSync(
          Duration.zero,
          Duration.zero,
          StreamTimeline.zero,
        ),
        isNull,
      );
    });

    test('returns null when position is out of range', () {
      expect(
        ProgressService.resolveSync(
          const Duration(seconds: 5000),
          const Duration(seconds: 3452),
          StreamTimeline.zero,
        ),
        isNull,
      );
    });
  });
}
