import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';
import 'package:player/presentation/widgets/video_controls/up_next_policy.dart';
import 'package:player/presentation/widgets/video_controls/up_next_prompt.dart';

const _target = UpNextTarget(
  episodeId: 'ep-8',
  fileId: 'file-8',
  seasonNumber: 1,
  episodeNumber: 8,
  title: 'Narkina 5',
  thumbnailUrl: 'https://example.test/8.jpg',
);

Future<void> _pump(
  WidgetTester tester, {
  UpNextTarget target = _target,
  required UpNextCountdown countdown,
  VoidCallback? onPlayNow,
  VoidCallback? onDismiss,
  ValueChanged<bool>? onEngagedChanged,
  double width = 1280,
}) async {
  tester.view.physicalSize = Size(width, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 720)),
        child: Scaffold(
          body: Stack(
            children: [
              UpNextPrompt(
                target: target,
                countdown: countdown,
                metrics: PanelMetrics.forWidth(width),
                onPlayNow: onPlayNow ?? () {},
                onDismiss: onDismiss ?? () {},
                onEngagedChanged: onEngagedChanged ?? (_) {},
                tier: PlayerGlassTier.faux,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  late UpNextCountdown countdown;

  setUp(() => countdown = UpNextCountdown(onElapsed: () {}));
  tearDown(() => countdown.dispose());

  group('resting pill', () {
    testWidgets('shows the eyebrow and episode code', (tester) async {
      await _pump(tester, countdown: countdown);
      expect(find.text('Next up · S1E8'), findsOneWidget);
    });

    testWidgets('reads "Next season" when the target crosses', (tester) async {
      await _pump(
        tester,
        countdown: countdown,
        target: const UpNextTarget(
          episodeId: 'ep-201',
          fileId: 'file-201',
          seasonNumber: 2,
          episodeNumber: 1,
          title: 'One Year Later',
          crossesSeason: true,
        ),
      );
      expect(find.text('Next season · S2E1'), findsOneWidget);
    });

    testWidgets('offers a dismiss without expanding first', (tester) async {
      // The requirement that drove the design: stopping must not cost an
      // interaction to reveal and another to confirm.
      await _pump(tester, countdown: countdown);
      expect(find.byKey(UpNextPrompt.dismissKey), findsOneWidget);
      expect(find.byKey(UpNextPrompt.cardKey), findsNothing);
    });

    testWidgets('calls onDismiss when the dismiss is tapped', (tester) async {
      var dismissed = 0;
      await _pump(tester, countdown: countdown, onDismiss: () => dismissed++);
      await tester.tap(find.byKey(UpNextPrompt.dismissKey));
      expect(dismissed, 1);
    });

    testWidgets('calls onPlayNow when Play is tapped', (tester) async {
      var played = 0;
      await _pump(tester, countdown: countdown, onPlayNow: () => played++);
      await tester.tap(find.byKey(UpNextPrompt.playKey));
      expect(played, 1);
    });

    testWidgets('gives both hit targets at least 44px of width',
        (tester) async {
      await _pump(tester, countdown: countdown, width: 360);
      expect(
        tester.getSize(find.byKey(UpNextPrompt.playKey)).width,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(find.byKey(UpNextPrompt.dismissKey)).width,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('puts dismiss at the trailing edge, right of Play',
        (tester) async {
      // So a thumb reaching for the stop cannot catch Play instead.
      await _pump(tester, countdown: countdown);
      expect(
        tester.getRect(find.byKey(UpNextPrompt.dismissKey)).left,
        greaterThan(tester.getRect(find.byKey(UpNextPrompt.playKey)).right - 1),
      );
    });

    testWidgets('anchors to the shared corner inset', (tester) async {
      await _pump(tester, countdown: countdown, width: 1280);
      final metrics = PanelMetrics.forWidth(1280);
      final pill = tester.getRect(find.byKey(UpNextPrompt.pillKey));
      expect(1280 - pill.right, closeTo(PanelMetrics.cornerInsetRight, 0.5));
      expect(720 - pill.bottom, closeTo(metrics.cornerInsetBottom, 0.5));
    });
  });

  group('expanded card', () {
    testWidgets('expands on tap and shows the still, code, and title',
        (tester) async {
      await _pump(tester, countdown: countdown);
      await tester.tap(find.byKey(UpNextPrompt.pillKey));
      await tester.pumpAndSettle();
      expect(find.byKey(UpNextPrompt.cardKey), findsOneWidget);
      expect(find.byKey(UpNextPrompt.stillKey), findsOneWidget);
      expect(find.text('S1E8'), findsOneWidget);
      expect(find.text('Narkina 5'), findsOneWidget);
      expect(find.text('Play now'), findsOneWidget);
    });

    testWidgets('omits the still entirely when there is no thumbnail',
        (tester) async {
      await _pump(tester,
          countdown: countdown,
          target: const UpNextTarget(
              episodeId: 'ep-8',
              fileId: 'file-8',
              seasonNumber: 1,
              episodeNumber: 8,
              title: 'Narkina 5'));
      await tester.tap(find.byKey(UpNextPrompt.pillKey));
      await tester.pumpAndSettle();
      expect(find.byKey(UpNextPrompt.cardKey), findsOneWidget);
      expect(find.byKey(UpNextPrompt.stillKey), findsNothing);
      expect(find.text('Narkina 5'), findsOneWidget);
    });

    testWidgets('keeps a working dismiss while expanded', (tester) async {
      var dismissed = 0;
      await _pump(tester, countdown: countdown, onDismiss: () => dismissed++);
      await tester.tap(find.byKey(UpNextPrompt.pillKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(UpNextPrompt.dismissKey));
      expect(dismissed, 1);
    });
  });

  group('engagement', () {
    testWidgets('reports engaged while expanded and disengaged after collapse',
        (tester) async {
      final engaged = <bool>[];
      await _pump(tester, countdown: countdown, onEngagedChanged: engaged.add);
      await tester.tap(find.byKey(UpNextPrompt.pillKey));
      await tester.pumpAndSettle();
      expect(engaged.last, isTrue);
      await tester.tap(find.byKey(UpNextPrompt.cardKey));
      await tester.pumpAndSettle();
      expect(engaged.last, isFalse);
    });

    testWidgets('reports engaged on pointer enter and disengaged on exit',
        (tester) async {
      final engaged = <bool>[];
      await _pump(tester, countdown: countdown, onEngagedChanged: engaged.add);
      final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await pointer.addPointer(location: Offset.zero);
      addTearDown(pointer.removePointer);
      await pointer.moveTo(tester.getCenter(find.byKey(UpNextPrompt.pillKey)));
      await tester.pump();
      expect(engaged.last, isTrue);
      await pointer.moveTo(Offset.zero);
      await tester.pump();
      expect(engaged.last, isFalse);
    });

    testWidgets('does not re-report the same engagement value', (tester) async {
      final engaged = <bool>[];
      await _pump(tester, countdown: countdown, onEngagedChanged: engaged.add);
      await tester.tap(find.byKey(UpNextPrompt.pillKey));
      await tester.pumpAndSettle();
      final afterExpand = engaged.length;
      await tester.pump(const Duration(seconds: 1));
      expect(engaged.length, afterExpand);
    });
  });
}
