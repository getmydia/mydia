import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/presentation/screens/player/segment_skipper.dart';

const _intro = MediaSegment(type: SegmentType.intro, startMs: 0, endMs: 60000);

void main() {
  group('SegmentSkipper', () {
    late SegmentSkipper skipper;
    late List<Duration> seeks;

    Future<void> seek(Duration to) async => seeks.add(to);

    setUp(() {
      skipper = SegmentSkipper()..autoSkip = true;
      seeks = [];
      skipper.resetIfMediaChanged('episode:1:a');
      skipper.setSegments(const [_intro]);
    });

    test('skips an actionable segment once per media', () {
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      skipper.maybeAutoSkip(const Duration(seconds: 6), seek);
      expect(seeks, [const Duration(minutes: 1)]);
    });

    test('does nothing with auto-skip off', () {
      skipper.autoSkip = false;
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(seeks, isEmpty);
    });

    test('a same-media reset keeps the skip consumed and the segments', () {
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(skipper.resetIfMediaChanged('episode:1:a'), isFalse);
      expect(skipper.segments, const [_intro]);
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(seeks, hasLength(1));
    });

    test('a media change clears segments and re-arms the skip', () {
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(skipper.resetIfMediaChanged('episode:2:b'), isTrue);
      expect(skipper.segments, isEmpty);
      skipper.setSegments(const [_intro]);
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(seeks, hasLength(2));
    });

    test('segmentAt finds the covering segment', () {
      expect(skipper.segmentAt(const Duration(seconds: 30)), _intro);
      expect(skipper.segmentAt(const Duration(minutes: 2)), isNull);
    });
  });
}
