import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/player/scrub_controller.dart';
import 'package:player/core/player/scrub_thumbnails.dart';
import 'package:player/core/player/thumbnail_service.dart';
import 'package:player/presentation/widgets/video_controls/scrub_bubble.dart';

void main() {
  group('scrubBubbleLeft', () {
    test('centres the bubble over the cursor', () {
      expect(
        scrubBubbleLeft(trackWidth: 1000, bubbleWidth: 176, fraction: 0.5),
        412,
      );
    });

    test('stops at the left edge', () {
      expect(
        scrubBubbleLeft(trackWidth: 1000, bubbleWidth: 176, fraction: 0.02),
        0,
      );
    });

    test('stops at the right edge', () {
      expect(
        scrubBubbleLeft(trackWidth: 1000, bubbleWidth: 176, fraction: 0.99),
        824,
      );
    });

    test('a track narrower than the bubble pins it left', () {
      expect(
        scrubBubbleLeft(trackWidth: 100, bubbleWidth: 176, fraction: 0.5),
        0,
      );
    });
  });

  group('formatScrubDelta', () {
    test('forward', () {
      expect(
          formatScrubDelta(const Duration(minutes: 2, seconds: 30)), '+02:30');
    });

    test('backward', () {
      expect(formatScrubDelta(const Duration(seconds: -40)), '-00:40');
    });

    test('past the hour', () {
      expect(
        formatScrubDelta(const Duration(hours: 1, seconds: 5)),
        '+01:00:05',
      );
    });
  });

  group('ScrubBubble', () {
    Widget host(Widget child) =>
        MaterialApp(home: Scaffold(body: Center(child: child)));

    testWidgets('shows the target and the delta', (tester) async {
      await tester.pumpWidget(host(const ScrubBubble(
        target: Duration(hours: 1, minutes: 2, seconds: 3),
        delta: Duration(minutes: 2, seconds: 30),
      )));

      expect(tester.widget<Text>(find.byKey(ScrubBubble.targetKey)).data,
          '01:02:03');
      expect(
          tester.widget<Text>(find.byKey(ScrubBubble.deltaKey)).data, '+02:30');
      expect(find.byKey(ScrubBubble.frameKey), findsNothing);
      expect(tester.getSize(find.byType(ScrubBubble)).width, ScrubBubble.width);
    });

    testWidgets('shows a frame when given one', (tester) async {
      await tester.pumpWidget(host(const ScrubBubble(
        target: Duration(minutes: 5),
        delta: Duration(seconds: 10),
        thumbnail: ColoredBox(color: Colors.red),
      )));

      expect(tester.getSize(find.byKey(ScrubBubble.frameKey)),
          const Size(ScrubBubble.frameWidth, ScrubBubble.frameHeight));
    });
  });

  group('ScrubBubbleAnchor', () {
    late Duration clock;
    late List<Duration> commits;
    late ScrubController scrub;

    setUp(() {
      clock = Duration.zero;
      commits = [];
      scrub = ScrubController(
        position: () => const Duration(minutes: 30),
        duration: () => const Duration(hours: 1),
        onCommit: (target) async => commits.add(target),
        elapsed: () => clock,
      );
    });

    Future<void> pump(WidgetTester tester, {ScrubThumbnails? thumbnails}) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: ScrubBubbleAnchor(
                  scrub: scrub,
                  thumbnails: thumbnails,
                  child: const SizedBox(key: Key('bar'), height: 32),
                ),
              ),
            ),
          ),
        ));

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      scrub.dispose();
    }

    testWidgets('floats over the cursor only while a scrub is active',
        (tester) async {
      await pump(tester);
      expect(find.byType(ScrubBubble), findsNothing);

      scrub.step(ScrubDirection.forward, isRepeat: false);
      await tester.pump();

      expect(find.byType(ScrubBubble), findsOneWidget);
      final bar = tester.getRect(find.byKey(const Key('bar')));
      final bubble = tester.getRect(find.byType(ScrubBubble));
      final expectedLeft = bar.left +
          scrubBubbleLeft(
            trackWidth: bar.width,
            bubbleWidth: ScrubBubble.width,
            fraction: scrub.displayFraction!,
          );
      expect(bubble.left, moreOrLessEquals(expectedLeft, epsilon: 0.5));
      expect(bubble.bottom,
          moreOrLessEquals(bar.top - ScrubBubbleAnchor.gap, epsilon: 0.5));
      expect(
          tester.widget<Text>(find.byKey(ScrubBubble.targetKey)).data, '30:10');

      await scrub.commit();
      await tester.pump();

      // Settling keeps the cursor on the bar, but the bubble is for choosing.
      expect(find.byType(ScrubBubble), findsNothing);
      await finish(tester);
    });

    testWidgets('fetches thumbnails on the first scrub, not before',
        (tester) async {
      var requests = 0;
      final thumbnails = ScrubThumbnails(
        service: ThumbnailService(
          serverUrl: 'https://media.example',
          authToken: 't',
          client: MockClient((_) async {
            requests++;
            return http.Response('', 404);
          }),
        ),
        fileId: 'file-1',
      );
      await pump(tester, thumbnails: thumbnails);
      expect(requests, 0);

      scrub.step(ScrubDirection.forward, isRepeat: false);
      await tester.pump();
      scrub.step(ScrubDirection.forward, isRepeat: false);
      await tester.pump();

      expect(requests, 1);
      expect(find.byKey(ScrubBubble.frameKey), findsNothing);
      await finish(tester);
      thumbnails.dispose();
    });
  });
}
