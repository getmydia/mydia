import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/core/window/window_frame_state.dart';
import 'package:player/presentation/widgets/window_chrome/desktop_window_chrome.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';
import 'package:player/presentation/widgets/window_chrome/window_drag_band.dart';
import 'package:player/presentation/widgets/window_chrome/window_resize_edges.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../core/window/fake_window_controller.dart';

/// `debugDefaultTargetPlatformOverride` is reset with a synchronous
/// try/finally rather than `addTearDown`: `TestWidgetsFlutterBinding`
/// verifies foundation debug vars are unset immediately after the test body
/// returns, which is before package:test unwinds its `addTearDown` queue.
/// Mirrors `window_chrome_inset_test.dart`.
Future<void> _pump(
  WidgetTester tester, {
  required TargetPlatform platform,
  required FakeWindowController window,
  DecorationLayout layout = const DecorationLayout(
    start: [],
    end: [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
  ),
  ValueListenable<bool>? fullscreen,
  ValueListenable<bool>? buttonsHidden,
  Widget child = const ColoredBox(color: Color(0xFF000000)),
  Future<void> Function()? body,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopWindowChrome(
          layout: ValueNotifier(layout),
          controller: window,
          fullscreen: fullscreen ?? ValueNotifier(false),
          buttonsHidden: buttonsHidden ?? ValueNotifier(false),
          child: child,
        ),
      ),
    );
    if (body != null) await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  // Same reasoning as `windowChromeInsetsFor`: `kIsWeb` is always false under
  // `flutter test`, so the web branch is only reachable through the pure
  // predicate.
  group('shouldShowWindowChrome', () {
    test('false on web, even when the platform reports Linux', () {
      expect(
        shouldShowWindowChrome(
          isWeb: true,
          platform: TargetPlatform.linux,
          isFullscreen: false,
        ),
        isFalse,
      );
    });

    test('true on windowed Linux', () {
      expect(
        shouldShowWindowChrome(
          isWeb: false,
          platform: TargetPlatform.linux,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('false in fullscreen, where the window has no chrome to draw', () {
      expect(
        shouldShowWindowChrome(
          isWeb: false,
          platform: TargetPlatform.linux,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('false on ${platform.name}, which draws no Flutter chrome', () {
        expect(
          shouldShowWindowChrome(
            isWeb: false,
            platform: platform,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }
  });

  // Pure for the same reason as `shouldShowWindowChrome`, and because GTK
  // squares its own frame in exactly these states: a mismatch leaves a
  // rounded app inside a square frame, or square app corners poking past a
  // rounded one.
  group('windowCornerRadiusFor', () {
    for (final maximized in [false, true]) {
      for (final tiled in [false, true]) {
        for (final fullscreen in [false, true]) {
          final state = WindowFrameState(
            maximized: maximized,
            tiled: tiled,
            fullscreen: fullscreen,
          );
          final expected = state.isFloating ? kLinuxWindowCornerRadius : 0.0;
          test('$state -> $expected', () {
            expect(windowCornerRadiusFor(state), expected);
          });
        }
      }
    }
  });

  group('DesktopWindowChrome', () {
    testWidgets('draws buttons and resize edges on Linux', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNWidgets(3));
          expect(find.byType(WindowResizeEdges), findsOneWidget);
        },
      );
    });

    testWidgets('draws no drag band of its own; title rows own dragging',
        (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        body: () async {
          expect(find.byType(WindowDragBand), findsNothing);
        },
      );
    });

    testWidgets('buttons occupy only their corner', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        body: () async {
          final close = tester.getRect(
            find.byKey(WindowButtonWidget.keyFor(WindowButton.close)),
          );
          final minimize = tester.getRect(
            find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)),
          );
          expect(close.right, lessThanOrEqualTo(800 - kLinuxChromeEdgePadding));
          expect(
            minimize.left,
            greaterThanOrEqualTo(800 - linuxButtonGroupReserve(3)),
          );
        },
      );
    });

    testWidgets('a tap in the middle of the top edge reaches the app',
        (tester) async {
      var tapped = false;
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        child: GestureDetector(
          onTap: () => tapped = true,
          child: const ColoredBox(color: Color(0xFF000000)),
        ),
        body: () async {
          await tester.tapAt(const Offset(400, kLinuxWindowChromeHeight / 2));
          expect(tapped, isTrue);
        },
      );
    });

    testWidgets('draws nothing on macOS, which keeps its native buttons',
        (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.macOS,
        window: FakeWindowController(),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNothing);
          expect(find.byType(WindowDragBand), findsNothing);
          expect(find.byType(WindowResizeEdges), findsNothing);
        },
      );
    });

    testWidgets('always renders its child, chrome or no chrome',
        (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.macOS,
        window: FakeWindowController(),
        body: () async => expect(find.byType(ColoredBox), findsWidgets),
      );
    });

    testWidgets('drops everything in fullscreen', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        fullscreen: ValueNotifier(true),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNothing);
          expect(find.byType(WindowResizeEdges), findsNothing);
        },
      );
    });

    testWidgets(
        'hides the buttons but KEEPS the resize edges while playback chrome '
        'is hidden. Losing the ability to resize mid-playback would be a '
        'regression', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        buttonsHidden: ValueNotifier(true),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNothing);
          expect(find.byType(WindowResizeEdges), findsOneWidget);
        },
      );
    });

    testWidgets('honours a start-side layout', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        layout: const DecorationLayout(
          start: [WindowButton.close],
          end: [WindowButton.minimize],
        ),
        body: () async {
          final close = tester.getCenter(
            find.byKey(WindowButtonWidget.keyFor(WindowButton.close)),
          );
          final minimize = tester.getCenter(
            find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)),
          );
          expect(close.dx, lessThan(minimize.dx));
        },
      );
    });
  });

  group('DesktopWindowChrome over a real WindowTitleRow', () {
    /// `debugDefaultTargetPlatformOverride` is reset in a synchronous
    /// `finally`, for the reason the file's own `_pump` doc comment records:
    /// the binding verifies foundation debug vars are unset the moment the
    /// test body returns, before package:test unwinds its `addTearDown`
    /// queue.
    ///
    /// Two separate `FakeWindowController`s stand in for what production
    /// wires as two separate concerns: [windowController] is
    /// `DesktopWindowChrome`'s own controller, which the Linux window
    /// buttons act on; [titleRowController] is the one `WindowTitleRow`
    /// passes to its own `WindowDragBand`. If a tap or drag on a button ever
    /// leaks past it, it shows up as a call on the *wrong* controller here,
    /// which a single shared fake could not distinguish.
    Future<void> onLinuxOverTitleRow(
      WidgetTester tester,
      Future<void> Function(
        FakeWindowController windowController,
        FakeWindowController titleRowController,
      ) body,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final windowController = FakeWindowController();
        final titleRowController = FakeWindowController();
        const layout = DecorationLayout(
          start: [],
          end: [
            WindowButton.minimize,
            WindowButton.maximize,
            WindowButton.close
          ],
        );

        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: DesktopWindowChrome(
                layout: ValueNotifier(layout),
                controller: windowController,
                fullscreen: ValueNotifier(false),
                buttonsHidden: ValueNotifier(false),
                child: WindowChromeInsets.scope(
                  insets: WindowChromeInsets(
                    height: kLinuxWindowChromeHeight,
                    leading: 0,
                    trailing: linuxButtonGroupReserve(layout.end.length),
                  ),
                  child: Scaffold(
                    body: WindowTitleRow(
                      controller: titleRowController,
                      showCast: false,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await body(windowController, titleRowController);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets(
        'a tap on minimize lands immediately, without waiting out '
        'kDoubleTapTimeout for a competing recognizer underneath',
        (tester) async {
      await onLinuxOverTitleRow(tester, (windowController, _) async {
        await tester.tap(
          find.byKey(WindowButtonWidget.keyFor(WindowButton.minimize)),
        );
        await tester.pump();

        expect(
          windowController.minimizeCalls,
          1,
          reason: 'a single pump (not pumpAndSettle, not a kDoubleTapTimeout '
              'wait) must already show the minimize call: nothing below the '
              'button entered the same gesture arena to hold it open',
        );
      });
    });

    testWidgets(
        'a double-tap on maximize never reaches the drag band underneath '
        'it', (tester) async {
      await onLinuxOverTitleRow(tester, (_, titleRowController) async {
        final maximizeButton =
            find.byKey(WindowButtonWidget.keyFor(WindowButton.maximize));
        await tester.tap(maximizeButton);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(maximizeButton);
        await tester.pump(kDoubleTapTimeout);

        expect(
          titleRowController.maximizeCalls,
          0,
          reason: 'the double-tap belongs to the button, not to '
              "WindowTitleRow's drag band, so the title row's own "
              'controller must never see a maximize call from it',
        );
        expect(titleRowController.unmaximizeCalls, 0);
        expect(
          titleRowController.startDraggingCalls,
          0,
          reason: 'two quick taps in place is not a drag either',
        );
      });
    });

    testWidgets(
        'a drag on empty band space, clear of the corner, still reaches '
        "the title row's own drag band", (tester) async {
      await onLinuxOverTitleRow(tester, (_, titleRowController) async {
        // x=300 is well clear of the end corner's reserved width (the
        // default layout's three end buttons only occupy the last ~110px),
        // so this point has nothing above `WindowTitleRow`'s own
        // `WindowDragBand` to absorb it.
        await tester.dragFrom(
          const Offset(300, kLinuxWindowChromeHeight / 2),
          const Offset(40, 0),
        );
        // The drag also arms the drag band's own double-tap recognizer,
        // which keeps a timer alive waiting for a second tap that never
        // comes; `flutter_test` fails the test over a pending timer at
        // teardown.
        await tester.pump(kDoubleTapTimeout);

        expect(titleRowController.startDraggingCalls, 1);
      });
    });
  });
}
