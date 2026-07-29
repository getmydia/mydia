import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, child: child)),
      ),
    );

void main() {
  group('ProgressBarSurface', () {
    testWidgets('renders a thumb at rest — the defect this fixes',
        (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      expect(find.byKey(ProgressBarSurface.thumbKey), findsOneWidget);
      final size = tester.getSize(find.byKey(ProgressBarSurface.thumbKey));
      expect(size.width, VideoProgressBar.restingThumbSize);
    });

    testWidgets('thumb and track grow on hover', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      // Resting state, asserted before any pointer interaction: half the
      // original complaint was the 3px hairline track, so its height at
      // rest gets its own assertion, not just the thumb's.
      final restingTrack =
          tester.getSize(find.byKey(ProgressBarSurface.trackKey));
      expect(restingTrack.height, 6.0);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ProgressBarSurface)));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byKey(ProgressBarSurface.thumbKey));
      expect(size.width, VideoProgressBar.activeThumbSize);
      final activeTrack =
          tester.getSize(find.byKey(ProgressBarSurface.trackKey));
      expect(activeTrack.height, 8.0);
    });

    testWidgets('renders played, buffered, and base track layers',
        (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      expect(find.byKey(ProgressBarSurface.trackKey), findsOneWidget);
      expect(find.byKey(ProgressBarSurface.bufferedKey), findsOneWidget);
      expect(find.byKey(ProgressBarSurface.playedKey), findsOneWidget);

      final buffered = tester.widget<FractionallySizedBox>(
        find.byKey(ProgressBarSurface.bufferedKey),
      );
      final played = tester.widget<FractionallySizedBox>(
        find.byKey(ProgressBarSurface.playedKey),
      );
      expect(buffered.widthFactor, 0.6);
      expect(played.widthFactor, 0.4);
    });

    testWidgets(
        'left-anchors the played and buffered fills to the track\'s '
        'left edge — regression guard for the centered-fill defect',
        (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      final track = tester.getRect(find.byKey(ProgressBarSurface.trackKey));
      final played = tester.getRect(find.byKey(ProgressBarSurface.playedKey));
      final buffered =
          tester.getRect(find.byKey(ProgressBarSurface.bufferedKey));

      expect(played.left, track.left);
      expect(played.width, closeTo(track.width * 0.4, 0.5));
      expect(buffered.left, track.left);
      expect(buffered.width, closeTo(track.width * 0.6, 0.5));
    });

    testWidgets('reports the tapped fraction', (tester) async {
      double? seeked;
      await tester.pumpWidget(
        _host(
          ProgressBarSurface(
            progress: 0.0,
            buffered: 0.0,
            onSeekTo: (f) => seeked = f,
          ),
        ),
      );

      final box = tester.getRect(find.byType(ProgressBarSurface));
      await tester.tapAt(Offset(box.left + box.width * 0.25, box.center.dy));
      await tester.pump();

      expect(seeked, isNotNull);
      expect(seeked!, closeTo(0.25, 0.02));
    });

    testWidgets('hit area meets the 44px touch minimum', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(
          progress: 0.4,
          buffered: 0.6,
          touchTarget: true,
        )),
      );

      final size = tester.getSize(find.byType(ProgressBarSurface));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('hit area defaults to the 32px pointer minimum',
        (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      final size = tester.getSize(find.byType(ProgressBarSurface));
      expect(size.height, 32);
    });

    testWidgets(
        'drag reports start, live updates, and commits the final '
        'position on end', (tester) async {
      final updates = <double>[];
      double? committed;
      var started = false;
      var ended = false;

      await tester.pumpWidget(
        _host(
          ProgressBarSurface(
            progress: 0.0,
            buffered: 0.0,
            onSeekStart: () => started = true,
            onSeekEnd: () => ended = true,
            onSeekUpdate: updates.add,
            onSeekTo: (f) => committed = f,
          ),
        ),
      );

      final box = tester.getRect(find.byType(ProgressBarSurface));
      final gesture = await tester.startGesture(
        Offset(box.left + box.width * 0.1, box.center.dy),
      );
      addTearDown(() => gesture.removePointer());

      // First move must clear the touch slop before the horizontal drag
      // recognizer accepts the gesture and fires onHorizontalDragStart.
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(started, isTrue);

      // While seeking, the thumb and track sit in the active (larger)
      // state — the same `_active` flag hover uses, exercised here via
      // the drag path instead.
      await tester.pumpAndSettle();
      final activeSize =
          tester.getSize(find.byKey(ProgressBarSurface.thumbKey));
      expect(activeSize.width, VideoProgressBar.activeThumbSize);

      await gesture.moveBy(const Offset(160, 0));
      await tester.pump();
      expect(updates, isNotEmpty);
      expect(updates.last, closeTo(0.6, 0.05));

      await gesture.up();
      await tester.pump();

      expect(ended, isTrue);
      expect(committed, isNotNull);
      expect(committed!, closeTo(0.6, 0.05));
    });

    testWidgets('clamps out-of-range fractions', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 1.8, buffered: -0.3)),
      );

      final played = tester.widget<FractionallySizedBox>(
        find.byKey(ProgressBarSurface.playedKey),
      );
      final buffered = tester.widget<FractionallySizedBox>(
        find.byKey(ProgressBarSurface.bufferedKey),
      );
      expect(played.widthFactor, 1.0);
      expect(buffered.widthFactor, 0.0);
    });
  });
}
