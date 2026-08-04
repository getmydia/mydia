import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';

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
  });
}
