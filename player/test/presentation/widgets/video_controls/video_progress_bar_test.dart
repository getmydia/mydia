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

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ProgressBarSurface)));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byKey(ProgressBarSurface.thumbKey));
      expect(size.width, VideoProgressBar.activeThumbSize);
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
