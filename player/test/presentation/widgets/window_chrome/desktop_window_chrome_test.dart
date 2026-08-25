import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/presentation/widgets/window_chrome/desktop_window_chrome.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';
import 'package:player/presentation/widgets/window_chrome/window_drag_band.dart';
import 'package:player/presentation/widgets/window_chrome/window_resize_edges.dart';

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
          child: const ColoredBox(color: Color(0xFF000000)),
        ),
      ),
    );
    if (body != null) await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  // Same reasoning as `windowChromeInsetFor`: `kIsWeb` is always false under
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

  group('DesktopWindowChrome', () {
    testWidgets('draws buttons, a drag band and resize edges on Linux',
        (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNWidgets(3));
          expect(find.byType(WindowDragBand), findsOneWidget);
          expect(find.byType(WindowResizeEdges), findsOneWidget);
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
          expect(find.byType(WindowDragBand), findsNothing);
          expect(find.byType(WindowResizeEdges), findsNothing);
        },
      );
    });

    testWidgets(
        'hides the buttons but KEEPS the resize edges while playback chrome '
        'is hidden — losing the ability to resize mid-playback would be a '
        'regression', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        buttonsHidden: ValueNotifier(true),
        body: () async {
          expect(find.byType(WindowButtonWidget), findsNothing);
          expect(find.byType(WindowDragBand), findsOneWidget);
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

    testWidgets('reserves exactly the band the inset reserves', (tester) async {
      await _pump(
        tester,
        platform: TargetPlatform.linux,
        window: FakeWindowController(),
        body: () async {
          expect(
            tester.getSize(find.byType(WindowDragBand)).height,
            kLinuxWindowChromeHeight,
          );
        },
      );
    });
  });
}
