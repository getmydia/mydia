import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/playback_surface.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('PlaybackSurface', () {
    testWidgets('a click with no movement toggles', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(PlaybackSurface(onTap: () => taps++)));

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets(
        'a mouse drag past the slop starts exactly one window drag and does '
        'not toggle', (tester) async {
      var taps = 0;
      var drags = 0;
      await tester.pumpWidget(
        _host(
          PlaybackSurface(
            onTap: () => taps++,
            onWindowDrag: () => drags++,
          ),
        ),
      );

      final gesture = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
      );
      // Several moves well past dragSlop: the drag must fire once, not once
      // per move event.
      await gesture.moveBy(const Offset(20, 0));
      await gesture.moveBy(const Offset(20, 0));
      await gesture.moveBy(const Offset(20, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drags, 1, reason: 'the OS drag must be handed off exactly once');
      expect(taps, 0, reason: 'a drag is not a click');
    });

    testWidgets('a mouse move under the slop starts no window drag',
        (tester) async {
      var drags = 0;
      await tester.pumpWidget(
        _host(
          PlaybackSurface(onTap: () {}, onWindowDrag: () => drags++),
        ),
      );

      final gesture = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(3, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drags, 0);
      // Deliberately no assertion about `taps` here. Flutter's own
      // TapGestureRecognizer uses kPrecisePointerHitSlop (1.0) for a mouse,
      // so it has already rejected this gesture as a tap regardless of
      // anything PlaybackSurface does. That 1px-to-8px dead zone predates
      // this widget.
    });

    testWidgets(
        'a touch drag between dragSlop and kTouchSlop drags the window and '
        'suppresses the toggle', (tester) async {
      // The case that actually exercises the suppression flag. A desktop
      // touchscreen gets kTouchSlop (18), so a 10px drag is still a tap as
      // far as Flutter is concerned, but is past this widget's 8px dragSlop.
      // Without the flag the window would move AND the chrome would toggle.
      var taps = 0;
      var drags = 0;
      await tester.pumpWidget(
        _host(
          PlaybackSurface(
            onTap: () => taps++,
            onWindowDrag: () => drags++,
          ),
        ),
      );

      final gesture = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.touch,
      );
      await gesture.moveBy(const Offset(10, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(drags, 1);
      expect(taps, 0, reason: 'the suppression flag did not hold');
    });

    testWidgets('a double-click fires onDoubleTap', (tester) async {
      var doubles = 0;
      await tester.pumpWidget(
        _host(
          PlaybackSurface(onTap: () {}, onDoubleTap: () => doubles++),
        ),
      );

      await tester.tapAt(const Offset(400, 300));
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(doubles, 1);
    });

    testWidgets('with onWindowDrag null a long drag does nothing',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(PlaybackSurface(onTap: () => taps++)));

      final gesture = await tester.startGesture(
        const Offset(400, 300),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(60, 0));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(taps, 0, reason: 'the mouse moved well past the 1px tap slop');
    });

    testWidgets(
        'with onDoubleTap null a tap resolves without waiting out the '
        'double-tap timeout', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(PlaybackSurface(onTap: () => taps++)));

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(taps, 1,
          reason: 'registering no double-tap handler must keep taps instant, '
              'which is what keeps mobile and the existing ChromeVisibility '
              'tests behaving as they do today');
    });

    testWidgets(
        'with onDoubleTap set a tap is deferred until the double-tap timeout',
        (tester) async {
      // Documents the accepted trade-off rather than guarding against it:
      // offering double-click-to-fullscreen costs an instant single click.
      var taps = 0;
      await tester.pumpWidget(
        _host(PlaybackSurface(onTap: () => taps++, onDoubleTap: () {})),
      );

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();
      expect(taps, 0, reason: 'the tap should still be waiting for a second');

      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      expect(taps, 1);
    });
  });
}
