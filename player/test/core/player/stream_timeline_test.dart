import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/stream_timeline.dart';

void main() {
  group('StreamTimeline.toReal', () {
    test('shifts a stream-local position by the start offset', () {
      const timeline = StreamTimeline(
        startOffset: Duration(seconds: 3600),
        totalDuration: Duration(seconds: 5400),
      );

      expect(timeline.toReal(const Duration(seconds: 120)),
          const Duration(seconds: 3720));
    });

    test('is the identity when there is no offset', () {
      expect(StreamTimeline.zero.toReal(const Duration(seconds: 42)),
          const Duration(seconds: 42));
    });
  });

  group('StreamTimeline.toPlayer', () {
    test('removes the start offset', () {
      const timeline = StreamTimeline(startOffset: Duration(seconds: 3600));

      expect(timeline.toPlayer(const Duration(seconds: 3720)),
          const Duration(seconds: 120));
    });

    test('clamps to zero for a real position before the offset', () {
      const timeline = StreamTimeline(startOffset: Duration(seconds: 3600));

      expect(timeline.toPlayer(const Duration(seconds: 60)), Duration.zero);
    });

    test('round-trips with toReal', () {
      const timeline = StreamTimeline(startOffset: Duration(seconds: 900));
      const playerPos = Duration(seconds: 77);

      expect(timeline.toPlayer(timeline.toReal(playerPos)), playerPos);
    });
  });

  group('StreamTimeline.resolveDuration', () {
    test('prefers the server duration over the partial playlist duration', () {
      // Regression: on a cold HLS stream the playlist is still growing, so the
      // player reports a small partial duration. Using it inflates progress to
      // 100% and is the original resume bug.
      const timeline = StreamTimeline(totalDuration: Duration(seconds: 5400));

      expect(timeline.resolveDuration(const Duration(seconds: 20)),
          const Duration(seconds: 5400));
    });

    test('falls back to offset plus player duration when the server is silent',
        () {
      // With an offset the player's own duration covers only the remainder of
      // the stream, so the real length is offset + remainder.
      const timeline = StreamTimeline(startOffset: Duration(seconds: 3600));

      expect(timeline.resolveDuration(const Duration(seconds: 1800)),
          const Duration(seconds: 5400));
    });

    test('falls back to the player duration when nothing is known', () {
      expect(StreamTimeline.zero.resolveDuration(const Duration(seconds: 3452)),
          const Duration(seconds: 3452));
    });

    test('ignores a non-positive server duration', () {
      const timeline = StreamTimeline(totalDuration: Duration.zero);

      expect(timeline.resolveDuration(const Duration(seconds: 300)),
          const Duration(seconds: 300));
    });
  });

  group('StreamTimeline equality', () {
    test('two timelines with the same fields are equal', () {
      expect(
        const StreamTimeline(
            startOffset: Duration(seconds: 10),
            totalDuration: Duration(seconds: 20)),
        const StreamTimeline(
            startOffset: Duration(seconds: 10),
            totalDuration: Duration(seconds: 20)),
      );
    });

    test('differing offsets are not equal', () {
      expect(
        const StreamTimeline(startOffset: Duration(seconds: 10)),
        isNot(const StreamTimeline(startOffset: Duration(seconds: 11))),
      );
    });
  });
}
