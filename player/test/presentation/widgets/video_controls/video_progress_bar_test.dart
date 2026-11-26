import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 400, child: child)),
  ),
);

void main() {
  group('ProgressBarSurface', () {
    Color fillColor(WidgetTester tester, Key key) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    testWidgets('played fill uses the palette primary', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );
      expect(
        fillColor(tester, ProgressBarSurface.playedKey),
        Palettes.projectionBooth.primary,
      );
    });

    testWidgets('buffered layer is white at 0.42', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );
      expect(
        fillColor(tester, ProgressBarSurface.bufferedKey),
        Colors.white.withValues(alpha: 0.42),
      );
    });

    testWidgets('base track rests 4 px tall in white at 0.22', (tester) async {
      await tester.pumpWidget(
        _host(
          ProgressBarSurface(progress: 0.4, buffered: 0.6, onSeekTo: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(ProgressBarSurface.trackKey)).height,
        4.0,
      );
      final track = tester.widget<AnimatedContainer>(
        find.byKey(ProgressBarSurface.trackKey),
      );
      expect(
        (track.decoration! as BoxDecoration).color,
        Colors.white.withValues(alpha: 0.22),
      );
    });

    Future<TestGesture> hover(WidgetTester tester) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ProgressBarSurface)));
      return gesture;
    }

    double thumbWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(ProgressBarSurface.thumbKey)).width;

    double trackHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(ProgressBarSurface.trackKey)).height;

    Widget seekable({bool focused = false}) => _host(
      ProgressBarSurface(
        progress: 0.4,
        buffered: 0.6,
        onSeekTo: (_) {},
        focused: focused,
      ),
    );

    testWidgets('thumb is hidden at rest and 18 when focused', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );
      expect(
        tester.getSize(find.byKey(ProgressBarSurface.thumbKey)),
        Size.zero,
      );
      await tester.pumpWidget(
        _host(
          const ProgressBarSurface(progress: 0.4, buffered: 0.6, focused: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(thumbWidth(tester), 18.0);
      expect(trackHeight(tester), VideoProgressBar.activeTrackHeight);
    });

    testWidgets('keeps a mounted thumb at rest with no size', (tester) async {
      await tester.pumpWidget(seekable());
      await tester.pumpAndSettle();

      expect(find.byKey(ProgressBarSurface.thumbKey), findsOneWidget);
      expect(thumbWidth(tester), VideoProgressBar.restingThumbSize);
      expect(VideoProgressBar.restingThumbSize, 0.0);
      expect(trackHeight(tester), VideoProgressBar.restingTrackHeight);
      expect(VideoProgressBar.restingTrackHeight, 4.0);
    });

    testWidgets('thumb and track grow on hover', (tester) async {
      await tester.pumpWidget(seekable());
      await tester.pumpAndSettle();
      expect(thumbWidth(tester), 0.0);
      expect(trackHeight(tester), 4.0);

      await hover(tester);
      await tester.pumpAndSettle();

      expect(thumbWidth(tester), VideoProgressBar.pointerThumbSize);
      expect(VideoProgressBar.pointerThumbSize, 14.0);
      expect(trackHeight(tester), 6.0);
    });

    testWidgets('returns to rest when the pointer leaves', (tester) async {
      await tester.pumpWidget(seekable());
      final gesture = await hover(tester);
      await tester.pumpAndSettle();
      expect(thumbWidth(tester), 14.0);

      await gesture.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(thumbWidth(tester), 0.0);
      expect(trackHeight(tester), 4.0);
    });

    testWidgets('with animations disabled one pump already shows the hover '
        'size', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: seekable(),
        ),
      );
      await hover(tester);
      await tester.pump();

      expect(thumbWidth(tester), 14.0);
      expect(trackHeight(tester), 6.0);
    });

    testWidgets('played fill is square-ended at rest and round when '
        'emphasized', (tester) async {
      BorderRadiusGeometry? playedRadius() {
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byKey(ProgressBarSurface.playedKey),
            matching: find.byType(DecoratedBox),
          ),
        );
        return (box.decoration as BoxDecoration).borderRadius;
      }

      await tester.pumpWidget(seekable());
      await tester.pumpAndSettle();
      final rest = playedRadius()!.resolve(TextDirection.ltr);
      expect(rest.topLeft, const Radius.circular(2));
      expect(rest.bottomLeft, const Radius.circular(2));
      expect(rest.topRight, Radius.zero);
      expect(rest.bottomRight, Radius.zero);

      await hover(tester);
      await tester.pumpAndSettle();
      final active = playedRadius()!.resolve(TextDirection.ltr);
      expect(active.topRight, const Radius.circular(3));
      expect(active.bottomRight, const Radius.circular(3));
      expect(active.topLeft, const Radius.circular(3));
    });

    testWidgets('renders played, buffered, and base track layers', (
      tester,
    ) async {
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

    testWidgets('left-anchors the played and buffered fills to the track\'s '
        'left edge — regression guard for the centered-fill defect', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      final track = tester.getRect(find.byKey(ProgressBarSurface.trackKey));
      final played = tester.getRect(find.byKey(ProgressBarSurface.playedKey));
      final buffered = tester.getRect(
        find.byKey(ProgressBarSurface.bufferedKey),
      );

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
        _host(
          const ProgressBarSurface(
            progress: 0.4,
            buffered: 0.6,
            touchTarget: true,
          ),
        ),
      );

      final size = tester.getSize(find.byType(ProgressBarSurface));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('hit area defaults to the 32px pointer minimum', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      final size = tester.getSize(find.byType(ProgressBarSurface));
      expect(size.height, 32);
    });

    testWidgets('drag reports start, live updates, and commits the final '
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
      final activeSize = tester.getSize(
        find.byKey(ProgressBarSurface.thumbKey),
      );
      expect(activeSize.width, VideoProgressBar.pointerThumbSize);
      expect(trackHeight(tester), VideoProgressBar.activeTrackHeight);

      await gesture.moveBy(const Offset(160, 0));
      await tester.pump();
      expect(updates, isNotEmpty);
      expect(updates.last, closeTo(0.6, 0.05));

      await gesture.up();
      await tester.pump();

      expect(ended, isTrue);
      expect(committed, isNotNull);
      expect(committed!, closeTo(0.6, 0.05));

      // The touch has lifted and no pointer hovers: back to rest.
      await gesture.removePointer();
      await tester.pumpAndSettle();
      expect(thumbWidth(tester), 0.0);
      expect(trackHeight(tester), 4.0);
    });

    testWidgets(
      'offers no interaction without onSeekTo — no hover affordance and '
      'no gesture handlers',
      (tester) async {
        await tester.pumpWidget(
          _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
        );

        expect(
          find.descendant(
            of: find.byType(ProgressBarSurface),
            matching: find.byType(GestureDetector),
          ),
          findsNothing,
        );

        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await tester.pump();
        await gesture.moveTo(tester.getCenter(find.byType(ProgressBarSurface)));
        await tester.pumpAndSettle();

        // Still at rest: hovering a read-only bar must not grow it.
        expect(
          tester.getSize(find.byKey(ProgressBarSurface.thumbKey)).width,
          VideoProgressBar.restingThumbSize,
        );
        expect(
          tester.getSize(find.byKey(ProgressBarSurface.trackKey)).height,
          4.0,
        );
        expect(
          tester.getSize(find.byKey(ProgressBarSurface.thumbKey)),
          Size.zero,
        );
      },
    );

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

  group('ProgressBarSurface scrub cursor', () {
    testWidgets('draws no cursor without a scrub', (tester) async {
      await tester.pumpWidget(
        _host(const ProgressBarSurface(progress: 0.4, buffered: 0.6)),
      );

      expect(find.byKey(ProgressBarSurface.scrubCursorKey), findsNothing);
      expect(find.byKey(ProgressBarSurface.scrubSpanKey), findsNothing);
    });

    testWidgets('centres the cursor on the scrub fraction', (tester) async {
      await tester.pumpWidget(
        _host(
          const ProgressBarSurface(
            progress: 0.25,
            buffered: 0.5,
            scrubFraction: 0.75,
          ),
        ),
      );

      final track = tester.getRect(find.byKey(ProgressBarSurface.trackKey));
      final cursor = tester.getRect(
        find.byKey(ProgressBarSurface.scrubCursorKey),
      );
      expect(
        cursor.center.dx,
        moreOrLessEquals(track.left + track.width * 0.75, epsilon: 0.5),
      );
      expect(cursor.width, VideoProgressBar.scrubCursorSize);
    });

    testWidgets('spans from the played position to the cursor', (tester) async {
      await tester.pumpWidget(
        _host(
          const ProgressBarSurface(
            progress: 0.25,
            buffered: 0.5,
            scrubFraction: 0.75,
          ),
        ),
      );

      final track = tester.getRect(find.byKey(ProgressBarSurface.trackKey));
      final span = tester.getRect(find.byKey(ProgressBarSurface.scrubSpanKey));
      expect(
        span.left,
        moreOrLessEquals(track.left + track.width * 0.25, epsilon: 0.5),
      );
      expect(span.width, moreOrLessEquals(track.width * 0.5, epsilon: 0.5));
    });

    testWidgets('spans backwards when the cursor is behind playback', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const ProgressBarSurface(
            progress: 0.6,
            buffered: 0.8,
            scrubFraction: 0.2,
          ),
        ),
      );

      final track = tester.getRect(find.byKey(ProgressBarSurface.trackKey));
      final span = tester.getRect(find.byKey(ProgressBarSurface.scrubSpanKey));
      expect(
        span.left,
        moreOrLessEquals(track.left + track.width * 0.2, epsilon: 0.5),
      );
      expect(span.width, moreOrLessEquals(track.width * 0.4, epsilon: 0.5));
    });

    testWidgets('focus thickens the track and grows the thumb', (tester) async {
      await tester.pumpWidget(
        _host(
          const ProgressBarSurface(progress: 0.4, buffered: 0.6, focused: true),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(ProgressBarSurface.trackKey)).height,
        VideoProgressBar.activeTrackHeight,
      );
      expect(
        tester.getSize(find.byKey(ProgressBarSurface.thumbKey)).width,
        VideoProgressBar.activeThumbSize,
      );
    });
  });
}
