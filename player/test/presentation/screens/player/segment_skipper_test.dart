import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/presentation/screens/player/segment_skipper.dart';

const _intro = MediaSegment(type: SegmentType.intro, startMs: 0, endMs: 60000);
const _breakA = MediaSegment(
  type: SegmentType.commercial,
  startMs: 600000,
  endMs: 720000,
);
const _breakB = MediaSegment(
  type: SegmentType.commercial,
  startMs: 1200000,
  endMs: 1260000,
);

void main() {
  group('SegmentSkipper', () {
    late SegmentSkipper skipper;
    late List<Duration> seeks;

    Future<void> seek(Duration to) async => seeks.add(to);

    setUp(() {
      skipper = SegmentSkipper()
        ..autoSkipIntroCredits = true
        ..preferencesLoaded();
      seeks = [];
      skipper.resetIfMediaChanged('episode:1:a');
      skipper.setSegments(const [_intro]);
    });

    test('skips an actionable segment once per media', () {
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      skipper.maybeAutoSkip(const Duration(seconds: 6), seek);
      expect(seeks, [const Duration(minutes: 1)]);
    });

    test('does nothing with intro auto-skip off', () {
      skipper.autoSkipIntroCredits = false;
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

    test('segmentAt offers a break nested inside an intro', () {
      const nested = MediaSegment(
        type: SegmentType.commercial,
        startMs: 10000,
        endMs: 50000,
      );
      skipper.setSegments(const [_intro, nested]);

      expect(skipper.segmentAt(const Duration(seconds: 5)), _intro);
      expect(skipper.segmentAt(const Duration(seconds: 20)), nested);
      expect(skipper.segmentAt(const Duration(seconds: 55)), _intro);
    });
  });

  group('SegmentSkipper before preferences load', () {
    test('never auto-skips until the stored choices are applied', () {
      final seeks = <Duration>[];
      Future<void> seek(Duration to) async => seeks.add(to);

      final skipper = SegmentSkipper()
        ..resetIfMediaChanged('episode:1:a')
        ..setSegments(const [_breakA]);

      skipper.maybeAutoSkip(const Duration(seconds: 601), seek);
      expect(seeks, isEmpty);

      skipper.preferencesLoaded();
      skipper.maybeAutoSkip(const Duration(seconds: 602), seek);
      expect(seeks, [const Duration(seconds: 720)]);
    });
  });

  group('SegmentSkipper per-type auto-skip', () {
    late SegmentSkipper skipper;
    late List<Duration> seeks;

    Future<void> seek(Duration to) async => seeks.add(to);

    setUp(() {
      skipper = SegmentSkipper()..preferencesLoaded();
      seeks = [];
      skipper.resetIfMediaChanged('episode:1:a');
      skipper.setSegments(const [_intro, _breakA, _breakB]);
    });

    test('by default commercials auto-skip and intros do not', () {
      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      expect(seeks, isEmpty);

      skipper.maybeAutoSkip(const Duration(seconds: 601), seek);
      expect(seeks, [const Duration(seconds: 720)]);
    });

    test('flipped settings skip intros and leave commercials', () {
      skipper
        ..autoSkipIntroCredits = true
        ..autoSkipCommercials = false;

      skipper.maybeAutoSkip(const Duration(seconds: 5), seek);
      skipper.maybeAutoSkip(const Duration(seconds: 601), seek);

      expect(seeks, [const Duration(minutes: 1)]);
    });

    test('seeking back into a spent break plays it', () {
      skipper.maybeAutoSkip(const Duration(seconds: 601), seek);
      skipper.maybeAutoSkip(const Duration(seconds: 650), seek);
      expect(seeks, [const Duration(seconds: 720)]);
    });

    test('each break skips once on its own', () {
      skipper.maybeAutoSkip(const Duration(seconds: 601), seek);
      skipper.maybeAutoSkip(const Duration(seconds: 1201), seek);
      expect(seeks, [
        const Duration(seconds: 720),
        const Duration(seconds: 1260),
      ]);
    });
  });
}
