import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(ChromeVisibility.contentKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  group('ChromeVisibility', () {
    testWidgets('starts visible', (tester) async {
      await tester.pumpWidget(
        _host(const ChromeVisibility(isPlaying: true, child: Text('chrome'))),
      );
      expect(_opacity(tester), 1.0);
    });

    testWidgets('hides after the auto-hide delay while playing',
        (tester) async {
      await tester.pumpWidget(
        _host(const ChromeVisibility(isPlaying: true, child: Text('chrome'))),
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0.0);
    });

    testWidgets('never hides while paused', (tester) async {
      await tester.pumpWidget(
        _host(const ChromeVisibility(isPlaying: false, child: Text('chrome'))),
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1.0);
    });

    testWidgets('never hides while seeking, even while playing',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            isSeeking: true,
            child: Text('chrome'),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1.0);
    });

    testWidgets('does not hide while the pointer is over chrome',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            child: SizedBox(width: 200, height: 100, child: Text('chrome')),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture
          .moveTo(tester.getCenter(find.byKey(ChromeVisibility.contentKey)));
      await tester.pump();

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1.0,
          reason: 'chrome hid under a resting cursor');
    });

    testWidgets(
        'keeps chrome shown once the mouse re-enters after it reappears '
        '(hover detection survives an IgnorePointer -> interactive flip)',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            child: SizedBox(width: 200, height: 100, child: Text('chrome')),
          ),
        ),
      );

      // Auto-hide with no pointer connected at all (same as the "hides
      // after the auto-hide delay" case above).
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0.0);

      // Now move a mouse pointer onto where the (still hidden, ignoring)
      // content sits. The outer desktop cursor MouseRegion's onHover fires on
      // this movement, bringing chrome back; separately, once `ignoring`
      // flips to false on the following frame, the content's own MouseRegion
      // must still pick up that the cursor is already resting inside it —
      // Flutter's mouse tracker re-hit-tests every connected device's last
      // known position once per frame specifically to catch a region
      // appearing/disappearing under a stationary cursor.
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(700, 500));
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture
          .moveTo(tester.getCenter(find.byKey(ChromeVisibility.contentKey)));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1.0);

      // If pointer-over-chrome were not detected here, the auto-hide timer
      // would still be running from `_show()` and would fire at 3s.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(
        _opacity(tester),
        1.0,
        reason: 'chrome hid again even though the cursor was already resting '
            'on it once it reappeared',
      );
    });

    testWidgets('reappears on tap after hiding', (tester) async {
      await tester.pumpWidget(
        _host(const ChromeVisibility(isPlaying: true, child: Text('chrome'))),
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0.0);

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 1.0);
    });

    testWidgets(
        'a tap on an empty region hides chrome while it is visible — the '
        'background toggle must not be permanently swallowed by an opaque '
        'MouseRegion over content', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            // Bounded and top-left, like the panel's real pills/controls —
            // NOT a bare `Text` directly, which `StackFit.expand` would force
            // to fill the whole screen. `RenderParagraph.hitTestSelf` is
            // unconditionally true across its *entire* box, not just where
            // glyphs are drawn, so an unbounded Text would self-hit
            // everywhere and mask exactly the regression this test targets.
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 100, height: 40, child: Text('chrome')),
            ),
          ),
        ),
      );

      expect(_opacity(tester), 1.0);

      // Tap well clear of the small, top-left content, while chrome is still
      // fully visible (well before the 3s auto-hide would fire).
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(
        _opacity(tester),
        0.0,
        reason: 'tap-to-hide while visible did not fire — the background '
            'GestureDetector is unreachable while chrome is shown',
      );
    });

    // --- Supplementary coverage below, added on top of the brief's own
    // test set. The brief only asserts the FadeTransition's opacity
    // property; these assert real hit-testing geometry, per direction: a
    // property check ("opacity is 0") cannot prove that hidden chrome
    // actually stops absorbing taps, only that it stopped being painted.

    testWidgets(
        'once fully hidden, a tap where a real control sits reaches the '
        'background toggle instead of the (invisible) control — proves '
        'IgnorePointer.ignoring actually takes effect, not just the fade',
        (tester) async {
      var buttonTapped = false;
      const buttonKey = Key('inner-button');
      await tester.pumpWidget(
        _host(
          ChromeVisibility(
            isPlaying: true,
            child: Align(
              alignment: Alignment.topLeft,
              child: GestureDetector(
                key: buttonKey,
                behavior: HitTestBehavior.opaque,
                onTap: () => buttonTapped = true,
                child: const SizedBox(width: 100, height: 60),
              ),
            ),
          ),
        ),
      );

      // Sanity: while visible, the inner control receives the tap.
      await tester.tap(find.byKey(buttonKey));
      expect(buttonTapped, isTrue, reason: 'control should work while shown');
      buttonTapped = false;

      // Auto-hide.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0.0);

      // Tap exactly where the (now hidden) control sits.
      await tester.tap(find.byKey(buttonKey), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(
        buttonTapped,
        isFalse,
        reason: 'hidden chrome must not still absorb taps meant for the '
            'background toggle',
      );
      // The tap should have been read as "reveal chrome" instead.
      expect(_opacity(tester), 1.0);
    });

    testWidgets(
        'a tap mid-hide-fade restores chrome rather than hiding it '
        'further (manual toggle reflects intent, not animation position)',
        (tester) async {
      await tester.pumpWidget(
        _host(const ChromeVisibility(isPlaying: true, child: Text('chrome'))),
      );

      // Trigger the auto-hide timer, then advance only partway into the
      // 250ms hide fade so the FadeTransition is still animating.
      await tester.pump(const Duration(seconds: 3, milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 50));
      final midFadeOpacity = _opacity(tester);
      expect(midFadeOpacity, greaterThan(0.0));
      expect(midFadeOpacity, lessThan(1.0));

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();

      expect(_opacity(tester), 1.0,
          reason: 'a tap mid-fade should bring chrome back, not finish '
              'hiding it');
    });

    testWidgets('hides immediately when the mouse leaves the window',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(width: 200, height: 60, child: Text('chrome')),
            ),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      // Enter over the content itself, not bare background. Leaving the
      // window from over a control fires the inner content MouseRegion's
      // onExit (clearing _pointerOverChrome) and the outer one's. Flutter
      // dispatches exits innermost first, so _pointerOverChrome is already
      // false when the outer handler evaluates _mayHide. If that ever
      // inverted, exiting over a control would silently stop hiding, and
      // this test is what would catch it.
      await gesture.addPointer(location: tester.getCenter(find.text('chrome')));
      addTearDown(gesture.removePointer);
      await tester.pump();
      expect(_opacity(tester), 1.0);

      // Move the pointer outside the 800x600 test window.
      await gesture.moveTo(const Offset(-50, -50));
      await tester.pumpAndSettle();

      expect(
        _opacity(tester),
        0.0,
        reason: 'chrome should not wait out the 3s timer once the pointer '
            'has left the window',
      );
    });

    testWidgets('does not hide on mouse exit while paused', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: false,
            child: SizedBox(width: 200, height: 100, child: Text('chrome')),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(const Offset(-50, -50));
      await tester.pumpAndSettle();

      expect(_opacity(tester), 1.0,
          reason: 'the paused invariant must survive mouse exit');
    });

    testWidgets('does not hide on mouse exit while seeking', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            isSeeking: true,
            child: SizedBox(width: 200, height: 100, child: Text('chrome')),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(const Offset(-50, -50));
      await tester.pumpAndSettle();

      expect(_opacity(tester), 1.0,
          reason: 'dragging the scrubber past the window edge must not '
              'yank the chrome away mid-seek');
    });

    testWidgets('does not hide on mouse exit while a modal route is on top',
        (tester) async {
      // Opening the quality, audio, subtitle or cast picker pushes a route
      // over the player and moves the pointer off it. Hiding underneath would
      // leave the chrome gone after dismissal until the mouse moved again,
      // because only onHover calls _show().
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            child: SizedBox(width: 200, height: 100, child: Text('chrome')),
          ),
        ),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      final context = tester.element(find.byType(ChromeVisibility));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('picker')),
        ),
      );
      await tester.pumpAndSettle();

      await gesture.moveTo(const Offset(-50, -50));
      await tester.pumpAndSettle();

      expect(_opacity(tester), 1.0,
          reason: 'chrome hid underneath an open selector');
    });
  });

  group('ChromeSlide', () {
    testWidgets(
        'the panel slides down (+offset) while the pills slide up '
        '(-offset) — opposite directions from the same animation',
        (tester) async {
      const markerKey = Key('slide-marker');
      await tester.pumpWidget(
        _host(
          const ChromeVisibility(
            isPlaying: true,
            child: Column(
              children: [
                ChromeSlide(
                  hiddenOffsetY: -6,
                  child: SizedBox(
                    key: Key('pill-marker'),
                    width: 40,
                    height: 20,
                  ),
                ),
                ChromeSlide(
                  hiddenOffsetY: 8,
                  child: SizedBox(
                    key: markerKey,
                    width: 40,
                    height: 20,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final pillTopAtRest =
          tester.getTopLeft(find.byKey(const Key('pill-marker'))).dy;
      final panelTopAtRest = tester.getTopLeft(find.byKey(markerKey)).dy;

      // Auto-hide.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final pillTopHidden =
          tester.getTopLeft(find.byKey(const Key('pill-marker'))).dy;
      final panelTopHidden = tester.getTopLeft(find.byKey(markerKey)).dy;

      expect(
        pillTopHidden - pillTopAtRest,
        closeTo(-6, 0.5),
        reason: 'top pills should rise (negative offset) when hidden',
      );
      expect(
        panelTopHidden - panelTopAtRest,
        closeTo(8, 0.5),
        reason: 'the panel should sink (positive offset) when hidden',
      );
    });

    testWidgets(
        'MediaQuery.disableAnimations drops the translate but the fade '
        'still runs', (tester) async {
      const markerKey = Key('slide-marker');
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _host(
            const ChromeVisibility(
              isPlaying: true,
              child: ChromeSlide(
                hiddenOffsetY: 8,
                child: SizedBox(key: markerKey, width: 40, height: 20),
              ),
            ),
          ),
        ),
      );

      final topAtRest = tester.getTopLeft(find.byKey(markerKey)).dy;

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final topHidden = tester.getTopLeft(find.byKey(markerKey)).dy;

      expect(
        topHidden,
        closeTo(topAtRest, 0.5),
        reason: 'disableAnimations should suppress the translate entirely',
      );
      // The fade is not suppressed: the content should still be invisible.
      expect(_opacity(tester), 0.0,
          reason: 'disableAnimations must not also cancel the fade');
    });

    testWidgets('renders the child unchanged with no ChromeAnimation ancestor',
        (tester) async {
      const markerKey = Key('slide-marker');
      await tester.pumpWidget(
        _host(
          const ChromeSlide(
            hiddenOffsetY: 8,
            child: SizedBox(key: markerKey, width: 40, height: 20),
          ),
        ),
      );

      expect(find.byKey(markerKey), findsOneWidget);
    });
  });
}
