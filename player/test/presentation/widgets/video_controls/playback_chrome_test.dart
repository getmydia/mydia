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

/// Reproduces the realistic Task 13 shape: an ancestor that flips
/// `isPlaying` via its own `setState` (driving [ChromeVisibility]'s
/// `didUpdateWidget` synchronously during that rebuild), whose
/// `onVisibilityChanged` callback itself calls `setState` in direct
/// response — the obvious thing to do to react to visibility (cursor,
/// system UI, wakelock). Pre-fix, that callback ran inline from
/// `didUpdateWidget`, which is itself called during an element-update phase,
/// so the nested `setState` would throw "setState() called during build".
class _DidUpdateWidgetHarness extends StatefulWidget {
  const _DidUpdateWidgetHarness();

  @override
  State<_DidUpdateWidgetHarness> createState() =>
      _DidUpdateWidgetHarnessState();
}

class _DidUpdateWidgetHarnessState extends State<_DidUpdateWidgetHarness> {
  bool _playing = true;
  int visibilityEvents = 0;

  void setPlaying(bool value) => setState(() => _playing = value);

  @override
  Widget build(BuildContext context) {
    return ChromeVisibility(
      isPlaying: _playing,
      onVisibilityChanged: (visible) => setState(() => visibilityEvents++),
      child: const Text('chrome'),
    );
  }
}

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

    testWidgets('reports visibility changes', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _host(
          ChromeVisibility(
            isPlaying: true,
            onVisibilityChanged: events.add,
            child: const Text('chrome'),
          ),
        ),
      );

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(events, contains(false));
    });

    testWidgets(
        'onVisibilityChanged does not throw "setState() called during '
        'build" when the consumer setStates in response, even when the '
        'visibility flip is driven synchronously from didUpdateWidget',
        (tester) async {
      await tester.pumpWidget(_host(const _DidUpdateWidgetHarness()));

      // Auto-hide while "playing".
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_opacity(tester), 0.0);
      expect(tester.takeException(), isNull);

      // Flip to "paused": this drives ChromeVisibility.didUpdateWidget
      // synchronously as part of the harness's own rebuild, which calls
      // _show() synchronously — the exact path that used to call
      // onVisibilityChanged inline.
      final harnessState = tester.state<_DidUpdateWidgetHarnessState>(
        find.byType(_DidUpdateWidgetHarness),
      );
      harnessState.setPlaying(false);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_opacity(tester), 1.0);
      expect(harnessState.visibilityEvents, greaterThan(0));
    });

    testWidgets(
        'a notification scheduled just before disposal does not fire and '
        'does not throw — the deferral must not trade a build-phase crash '
        'for a post-dispose one', (tester) async {
      final events = <bool>[];
      await tester.pumpWidget(
        _host(
          ChromeVisibility(
            isPlaying: true,
            onVisibilityChanged: events.add,
            // Bounded and top-left, so the tap below (at an empty region)
            // reaches the background toggle rather than self-hitting via
            // RenderParagraph — see the "empty region" test above.
            child: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 100, height: 40, child: Text('chrome')),
            ),
          ),
        ),
      );

      // Chrome starts visible, so this tap calls _hide(), which schedules
      // the deferred notification via addPostFrameCallback. `tap()` only
      // dispatches raw pointer events — it does not itself pump a frame —
      // so nothing has fired yet.
      await tester.tapAt(const Offset(400, 300));

      // Swap in an entirely different tree. This single pumpWidget call
      // disposes ChromeVisibility's State during its build phase, then, in
      // the very same frame, runs the already-scheduled post-frame
      // callback — exercising the exact race: scheduled while mounted,
      // firing after disposal.
      await tester.pumpWidget(_host(const SizedBox()));

      expect(tester.takeException(), isNull);
      expect(
        events,
        isEmpty,
        reason: 'onVisibilityChanged fired after the widget was disposed',
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
