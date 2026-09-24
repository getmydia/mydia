import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/window/decoration_layout.dart';
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
  const endOnly = DecorationLayout(
    start: [],
    end: [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
  );
  const both = DecorationLayout(
    start: [WindowButton.close],
    end: [WindowButton.minimize, WindowButton.maximize],
  );

  WindowChromeInsets resolve({
    bool isWeb = false,
    required TargetPlatform platform,
    bool isFullscreen = false,
    DecorationLayout layout = endOnly,
    TextDirection dir = TextDirection.ltr,
  }) =>
      windowChromeInsetsFor(
        isWeb: isWeb,
        platform: platform,
        isFullscreen: isFullscreen,
        decorationLayout: layout,
        textDirection: dir,
      );

  // `kIsWeb` is a compile-time constant baked in per build target — it is
  // always `false` under `flutter test`, so a regression that deleted the
  // web check from `WindowChromeInset.build` (see that method's doc comment)
  // would pass every widget test in this file, since none of them can ever
  // observe `kIsWeb` being `true`. Testing the extracted logic with explicit
  // inputs is the only way to verify the web branch without a browser test
  // target — mirrors
  // `platform_features_keyboard_test.dart`/`computeSupportsKeyboardShortcuts`.
  group('windowChromeInsetsFor', () {
    test('zero on web even on macOS and Linux (kIsWeb is false under test)',
        () {
      expect(resolve(isWeb: true, platform: TargetPlatform.macOS),
          WindowChromeInsets.zero);
      expect(resolve(isWeb: true, platform: TargetPlatform.linux),
          WindowChromeInsets.zero);
    });

    for (final platform in TargetPlatform.values) {
      test('zero in fullscreen on ${platform.name}', () {
        expect(resolve(platform: platform, isFullscreen: true),
            WindowChromeInsets.zero);
      });
    }

    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
      TargetPlatform.windows,
    ]) {
      test('zero on ${platform.name}', () {
        expect(resolve(platform: platform), WindowChromeInsets.zero);
      });
    }

    test('macOS reserves the traffic lights on the leading side', () {
      expect(
        resolve(platform: TargetPlatform.macOS),
        const WindowChromeInsets(
            height: kMacTitleBarOverlap,
            leading: kMacTrafficLightsWidth,
            trailing: 0),
      );
    });

    test('macOS lights stay physically left, so RTL moves them to trailing',
        () {
      expect(
        resolve(platform: TargetPlatform.macOS, dir: TextDirection.rtl),
        const WindowChromeInsets(
            height: kMacTitleBarOverlap,
            leading: 0,
            trailing: kMacTrafficLightsWidth),
      );
    });

    test('the traffic lights end at x 71, inside the reserve', () {
      expect(kMacTrafficLightsWidth, greaterThan(71));
    });

    test('Linux reserves each side by its button count', () {
      expect(
        resolve(platform: TargetPlatform.linux),
        WindowChromeInsets(
            height: kLinuxWindowChromeHeight,
            leading: 0,
            trailing: linuxButtonGroupReserve(3)),
      );
      expect(
        resolve(platform: TargetPlatform.linux, layout: both),
        WindowChromeInsets(
            height: kLinuxWindowChromeHeight,
            leading: linuxButtonGroupReserve(1),
            trailing: linuxButtonGroupReserve(2)),
      );
    });

    test('Linux sides are already directional, so RTL does not swap them', () {
      expect(
        resolve(platform: TargetPlatform.linux, dir: TextDirection.rtl),
        resolve(platform: TargetPlatform.linux),
      );
    });

    test('an empty Linux group reserves nothing', () {
      expect(linuxButtonGroupReserve(0), 0);
      expect(linuxButtonGroupReserve(2), 6 + 2 * 32 + 8);
    });
  });

  group('WindowChromeInsets scope', () {
    testWidgets('WindowChromeInset publishes the resolved insets',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        late WindowChromeInsets seen;
        await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: WindowChromeInset(
            fullscreen: ValueNotifier(false),
            decorationLayout: ValueNotifier(endOnly),
            child: Builder(builder: (context) {
              seen = WindowChromeInsets.of(context);
              return const SizedBox.shrink();
            }),
          ),
        ));
        expect(seen.leading, kMacTrafficLightsWidth);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('of() is zero with no scope above', (tester) async {
      late WindowChromeInsets seen;
      await tester.pumpWidget(Builder(builder: (context) {
        seen = WindowChromeInsets.of(context);
        return const SizedBox.shrink();
      }));
      expect(seen, WindowChromeInsets.zero);
    });

    testWidgets('removeBand removes only the band, keeping a status bar',
        (tester) async {
      late double top;
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(top: 24 + 40)),
        child: WindowChromeInsets.scope(
          insets:
              const WindowChromeInsets(height: 40, leading: 80, trailing: 0),
          child: WindowChromeInsets.removeBand(
            child: Builder(builder: (context) {
              top = MediaQuery.paddingOf(context).top;
              return const SizedBox.shrink();
            }),
          ),
        ),
      ));
      expect(top, 24);
    });
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

    testWidgets('reserves the button band on windowed Linux', (tester) async {
      final top = await _topPaddingUnder(
        tester,
        platform: TargetPlatform.linux,
        fullscreen: ValueNotifier(false),
      );

      expect(top, kLinuxWindowChromeHeight);
    });

    testWidgets('reserves nothing on fullscreen Linux', (tester) async {
      final top = await _topPaddingUnder(
        tester,
        platform: TargetPlatform.linux,
        fullscreen: ValueNotifier(true),
      );

      expect(top, 0);
    });

    for (final platform in [
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
