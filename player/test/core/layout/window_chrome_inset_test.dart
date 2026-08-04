import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/window/window_fullscreen.dart';

/// Captures the top padding its subtree sees, so each test asserts on the
/// value a real screen would read rather than on the widget's internals.
class _PaddingProbe extends StatelessWidget {
  const _PaddingProbe({required this.onBuild});

  final void Function(double top) onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild(MediaQuery.of(context).padding.top);
    return const SizedBox.shrink();
  }
}

// `debugDefaultTargetPlatformOverride` is reset with a synchronous
// try/finally rather than `addTearDown`: `TestWidgetsFlutterBinding`
// verifies foundation debug vars are unset immediately after the test body
// returns, which is before package:test unwinds its `addTearDown` queue, so
// an `addTearDown`-based reset trips
// `debugAssertAllFoundationVarsUnset` on every run.
Future<double> _topPaddingUnder(
  WidgetTester tester, {
  required TargetPlatform platform,
  required ValueListenable<bool> fullscreen,
  double existingTop = 0,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    late double captured;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(padding: EdgeInsets.only(top: existingTop)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: WindowChromeInset(
            fullscreen: fullscreen,
            child: _PaddingProbe(onBuild: (top) => captured = top),
          ),
        ),
      ),
    );
    return captured;
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  // `kIsWeb` is a compile-time constant baked in per build target — it is
  // always `false` under `flutter test`, so a regression that deleted the
  // web check from `WindowChromeInset.build` (see that method's doc comment)
  // would pass every widget test in this file, since none of them can ever
  // observe `kIsWeb` being `true`. Testing the extracted boolean logic with
  // explicit inputs is the only way to verify the web branch without a
  // browser test target — mirrors
  // `platform_features_keyboard_test.dart`/`computeSupportsKeyboardShortcuts`.
  group('shouldReserveTitleBar', () {
    test(
        'false on web, even on macOS — the regression this predicate exists '
        'to catch: a deleted kIsWeb check would still pass every other test '
        'in this file, since kIsWeb is always false under flutter test', () {
      expect(
        shouldReserveTitleBar(
          isWeb: true,
          platform: TargetPlatform.macOS,
          isFullscreen: false,
        ),
        isFalse,
      );
    });

    test('true on windowed macOS, off web', () {
      expect(
        shouldReserveTitleBar(
          isWeb: false,
          platform: TargetPlatform.macOS,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('false on fullscreen macOS, off web', () {
      expect(
        shouldReserveTitleBar(
          isWeb: false,
          platform: TargetPlatform.macOS,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('false on ${platform.name}, off web', () {
        expect(
          shouldReserveTitleBar(
            isWeb: false,
            platform: platform,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }
  });

  group('WindowChromeInset', () {
    testWidgets('reserves the traffic light strip on windowed macOS',
        (tester) async {
      final top = await _topPaddingUnder(
        tester,
        platform: TargetPlatform.macOS,
        fullscreen: ValueNotifier(false),
      );

      expect(top, kMacTitleBarOverlap);
    });

    testWidgets('adds to any inset already present rather than replacing it',
        (tester) async {
      final top = await _topPaddingUnder(
        tester,
        platform: TargetPlatform.macOS,
        fullscreen: ValueNotifier(false),
        existingTop: 12,
      );

      expect(top, 12 + kMacTitleBarOverlap);
    });

    testWidgets('reserves nothing in fullscreen, where macOS hides the lights',
        (tester) async {
      final top = await _topPaddingUnder(
        tester,
        platform: TargetPlatform.macOS,
        fullscreen: ValueNotifier(true),
      );

      expect(top, 0);
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets('reserves nothing on ${platform.name}', (tester) async {
        final top = await _topPaddingUnder(
          tester,
          platform: platform,
          fullscreen: ValueNotifier(false),
        );

        expect(top, 0);
      });
    }

    testWidgets('drops the inset live when the window enters fullscreen',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final fullscreen = ValueNotifier(false);
        final seen = <double>[];

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: WindowChromeInset(
                fullscreen: fullscreen,
                child: _PaddingProbe(onBuild: seen.add),
              ),
            ),
          ),
        );
        expect(seen.last, kMacTitleBarOverlap);

        fullscreen.value = true;
        await tester.pump();
        expect(seen.last, 0);

        fullscreen.value = false;
        await tester.pump();
        expect(seen.last, kMacTitleBarOverlap);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'falls back to the real windowFullscreenSignal when no fullscreen '
        'listenable is injected', (tester) async {
      // Every other test in this file injects `fullscreen:`, which never
      // exercises the `_fullscreen ?? windowFullscreen` fallback in
      // `WindowChromeInset.build` — this is the one test that drives the
      // real app-wide signal instead. try/finally so a failed assertion
      // still restores the global to its default (`false`) rather than
      // leaking `true` into whichever test runs next in this process.
      final originalValue = windowFullscreenSignal.value;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        windowFullscreenSignal.value = false;
        late double captured;

        await tester.pumpWidget(
          MediaQuery(
            data: const MediaQueryData(),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: WindowChromeInset(
                child: _PaddingProbe(onBuild: (top) => captured = top),
              ),
            ),
          ),
        );
        expect(captured, kMacTitleBarOverlap);

        windowFullscreenSignal.value = true;
        await tester.pump();
        expect(captured, 0);
      } finally {
        windowFullscreenSignal.value = originalValue;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
