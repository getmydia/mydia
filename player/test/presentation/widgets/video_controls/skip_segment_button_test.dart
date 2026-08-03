import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/presentation/widgets/video_controls/skip_segment_button.dart';

void main() {
  const intro = MediaSegment(
    type: SegmentType.intro,
    startMs: 30000,
    endMs: 90000,
  );
  const credits = MediaSegment(
    type: SegmentType.credits,
    startMs: 1200000,
    endMs: 1260000,
  );

  group('MediaSegment', () {
    test('parses graphql json', () {
      final segment = MediaSegment.fromJson(const {
        'type': 'INTRO',
        'startMs': 30000,
        'endMs': 90000,
      });

      expect(segment.type, SegmentType.intro);
      expect(segment.startMs, 30000);
      expect(segment.endMs, 90000);
    });

    test('falls back to unknown for an unrecognised type', () {
      final segment = MediaSegment.fromJson(const {
        'type': 'RECAP',
        'startMs': 0,
        'endMs': 1000,
      });

      expect(segment.type, SegmentType.unknown);
      expect(segment.actionable, isFalse);
    });

    test('containsPosition is inclusive of start and exclusive of end', () {
      expect(
          intro.containsPosition(const Duration(milliseconds: 29999)), isFalse);
      expect(
          intro.containsPosition(const Duration(milliseconds: 30000)), isTrue);
      expect(
          intro.containsPosition(const Duration(milliseconds: 89999)), isTrue);
      expect(
          intro.containsPosition(const Duration(milliseconds: 90000)), isFalse);
    });

    // A newer player regularly meets an older server with no segments field,
    // which fails the whole query rather than returning null for that one
    // selection. Every shape below has to mean "no skip buttons".
    test('listFromJson yields an empty list for anything malformed', () {
      expect(MediaSegment.listFromJson(null), isEmpty);
      expect(MediaSegment.listFromJson('nope'), isEmpty);
      expect(MediaSegment.listFromJson(const [42, 'x']), isEmpty);
      expect(MediaSegment.listFromJson(const <dynamic>[]), isEmpty);
    });

    test('listFromJson parses a well-formed list', () {
      final segments = MediaSegment.listFromJson(const [
        {'type': 'INTRO', 'startMs': 30000, 'endMs': 90000},
        {'type': 'CREDITS', 'startMs': 1200000, 'endMs': 1260000},
      ]);

      expect(segments, [intro, credits]);
    });
  });

  // `forFile` is what the player screen actually calls on the segments query
  // response. It reads the raw payload rather than a generated result class,
  // so every shape a strange or older server can produce has to land on an
  // empty list instead of a cast error.
  group('MediaSegment.forFile', () {
    Map<String, dynamic> payload(Object? files) => {
          '__typename': 'Query',
          'movie': {
            '__typename': 'Movie',
            'id': 'movie-1',
            'files': files,
          },
        };

    Map<String, dynamic> file(String id, Object? segments) => {
          '__typename': 'MediaFile',
          'id': id,
          'segments': segments,
        };

    const introJson = {
      '__typename': 'MediaSegment',
      'type': 'INTRO',
      'startMs': 30000,
      'endMs': 90000,
    };

    test('picks the segments belonging to the file being played', () {
      final segments = MediaSegment.forFile(
        payload([
          file('other-file', const []),
          file('file-1', const [introJson]),
        ]),
        root: 'movie',
        fileId: 'file-1',
      );

      expect(segments, [intro]);
    });

    test('returns empty when no file matches', () {
      expect(
        MediaSegment.forFile(
          payload([
            file('other-file', const [introJson])
          ]),
          root: 'movie',
          fileId: 'file-1',
        ),
        isEmpty,
      );
    });

    test('drops segments of an unrecognised type', () {
      final segments = MediaSegment.forFile(
        payload([
          file('file-1', const [
            {'type': 'RECAP', 'startMs': 0, 'endMs': 1000},
            introJson,
          ]),
        ]),
        root: 'movie',
        fileId: 'file-1',
      );

      expect(segments, [intro]);
    });

    test('returns empty for a missing or malformed payload', () {
      expect(
        MediaSegment.forFile(null, root: 'movie', fileId: 'file-1'),
        isEmpty,
      );
      expect(
        MediaSegment.forFile(const {}, root: 'movie', fileId: 'file-1'),
        isEmpty,
      );
      expect(
        MediaSegment.forFile(
          const {'movie': null},
          root: 'movie',
          fileId: 'file-1',
        ),
        isEmpty,
      );
      expect(
        MediaSegment.forFile(payload(null), root: 'movie', fileId: 'file-1'),
        isEmpty,
      );
      expect(
        MediaSegment.forFile(
          payload(const ['nonsense']),
          root: 'movie',
          fileId: 'file-1',
        ),
        isEmpty,
      );
      expect(
        MediaSegment.forFile(
          payload([file('file-1', 'nonsense')]),
          root: 'movie',
          fileId: 'file-1',
        ),
        isEmpty,
      );
    });

    test('returns empty when the root field is absent', () {
      expect(
        MediaSegment.forFile(
          payload([
            file('file-1', const [introJson])
          ]),
          root: 'episode',
          fileId: 'file-1',
        ),
        isEmpty,
      );
    });
  });

  group('SegmentSkipTracker', () {
    test('permits a segment only once per session', () {
      final tracker = SegmentSkipTracker();

      expect(tracker.shouldAutoSkip(intro), isTrue);
      tracker.markSkipped(intro);
      expect(tracker.shouldAutoSkip(intro), isFalse);
    });

    test('reset clears the record so a new media item skips again', () {
      final tracker = SegmentSkipTracker();

      tracker.markSkipped(intro);
      tracker.reset();

      expect(tracker.shouldAutoSkip(intro), isTrue);
    });

    test('takeAutoSkip returns the segment covering the position', () {
      final tracker = SegmentSkipTracker();

      expect(
        tracker
            .takeAutoSkip(const [intro, credits], const Duration(seconds: 45)),
        intro,
      );
    });

    test('takeAutoSkip returns null outside every segment', () {
      final tracker = SegmentSkipTracker();

      expect(
        tracker
            .takeAutoSkip(const [intro, credits], const Duration(seconds: 10)),
        isNull,
      );
    });

    // The guard that makes auto-skip survivable: seeking back into an intro
    // that has already been skipped must leave playback alone, or the viewer
    // can never watch it.
    test('takeAutoSkip does not re-trigger after seeking back in', () {
      final tracker = SegmentSkipTracker();
      const segments = [intro, credits];

      expect(
        tracker.takeAutoSkip(segments, const Duration(seconds: 31)),
        intro,
      );
      // Viewer seeks back to the top of the intro, then plays through it.
      expect(
          tracker.takeAutoSkip(segments, const Duration(seconds: 31)), isNull);
      expect(
          tracker.takeAutoSkip(segments, const Duration(seconds: 45)), isNull);
      expect(
          tracker.takeAutoSkip(segments, const Duration(seconds: 89)), isNull);
    });

    test('a spent intro does not disarm the credits', () {
      final tracker = SegmentSkipTracker();
      const segments = [intro, credits];

      tracker.takeAutoSkip(segments, const Duration(seconds: 45));

      expect(
        tracker.takeAutoSkip(segments, const Duration(seconds: 1201)),
        credits,
      );
    });

    test('takeAutoSkip ignores segments of an unrecognised type', () {
      final tracker = SegmentSkipTracker();
      const unknown = MediaSegment(
        type: SegmentType.unknown,
        startMs: 0,
        endMs: 60000,
      );

      expect(
        tracker.takeAutoSkip(const [unknown], const Duration(seconds: 10)),
        isNull,
      );
    });

    test('reset re-arms takeAutoSkip on media change', () {
      final tracker = SegmentSkipTracker();
      const segments = [intro];

      tracker.takeAutoSkip(segments, const Duration(seconds: 45));
      tracker.reset();

      expect(
          tracker.takeAutoSkip(segments, const Duration(seconds: 45)), intro);
    });
  });

  group('SkipSegmentButton', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    Widget button({
      MediaSegment segment = intro,
      required Duration position,
      void Function(MediaSegment)? onSkip,
    }) =>
        SkipSegmentButton(
          segment: segment,
          position: position,
          onSkip: onSkip ?? (_) {},
          // Pinned so the surface does not vary with the host platform.
          tier: PlayerGlassTier.full,
        );

    testWidgets('shows the intro label while inside the segment',
        (tester) async {
      await tester
          .pumpWidget(wrap(button(position: const Duration(seconds: 45))));

      expect(find.text('Skip Intro'), findsOneWidget);
      expect(find.byKey(SkipSegmentButton.buttonKey), findsOneWidget);
    });

    testWidgets('appears exactly at the segment start', (tester) async {
      await tester.pumpWidget(
        wrap(button(position: const Duration(milliseconds: 29999))),
      );
      expect(find.byKey(SkipSegmentButton.buttonKey), findsNothing);

      await tester.pumpWidget(
        wrap(button(position: const Duration(milliseconds: 30000))),
      );
      expect(find.byKey(SkipSegmentButton.buttonKey), findsOneWidget);
    });

    testWidgets('disappears exactly at the segment end', (tester) async {
      await tester.pumpWidget(
        wrap(button(position: const Duration(milliseconds: 89999))),
      );
      expect(find.byKey(SkipSegmentButton.buttonKey), findsOneWidget);

      await tester.pumpWidget(
        wrap(button(position: const Duration(milliseconds: 90000))),
      );
      expect(find.byKey(SkipSegmentButton.buttonKey), findsNothing);
    });

    testWidgets('renders nothing before the segment starts', (tester) async {
      await tester
          .pumpWidget(wrap(button(position: const Duration(seconds: 10))));

      expect(find.text('Skip Intro'), findsNothing);
    });

    testWidgets('renders nothing after the segment ends', (tester) async {
      await tester
          .pumpWidget(wrap(button(position: const Duration(seconds: 120))));

      expect(find.text('Skip Intro'), findsNothing);
    });

    testWidgets('shows the credits label for a credits segment',
        (tester) async {
      await tester.pumpWidget(wrap(button(
        segment: credits,
        position: const Duration(seconds: 1210),
      )));

      expect(find.text('Skip Credits'), findsOneWidget);
    });

    testWidgets('renders nothing for an unrecognised segment type',
        (tester) async {
      await tester.pumpWidget(wrap(button(
        segment: const MediaSegment(
          type: SegmentType.unknown,
          startMs: 0,
          endMs: 60000,
        ),
        position: const Duration(seconds: 10),
      )));

      expect(find.byKey(SkipSegmentButton.buttonKey), findsNothing);
    });

    testWidgets('reports the segment end when tapped', (tester) async {
      MediaSegment? skipped;

      await tester.pumpWidget(wrap(button(
        position: const Duration(seconds: 45),
        onSkip: (segment) => skipped = segment,
      )));

      await tester.tap(find.text('Skip Intro'));
      await tester.pump();

      expect(skipped, isNotNull);
      expect(skipped!.endMs, 90000);
      expect(skipped!.end, const Duration(milliseconds: 90000));
    });

    // Manual skipping stays available for a segment auto-skip already spent:
    // the once-per-session guard governs the automatic seek, not the button.
    testWidgets('still renders for a segment already auto-skipped',
        (tester) async {
      final tracker = SegmentSkipTracker();
      tracker.takeAutoSkip(const [intro], const Duration(seconds: 31));

      await tester
          .pumpWidget(wrap(button(position: const Duration(seconds: 45))));

      expect(find.byKey(SkipSegmentButton.buttonKey), findsOneWidget);
      expect(tracker.shouldAutoSkip(intro), isFalse);
    });
  });
}
