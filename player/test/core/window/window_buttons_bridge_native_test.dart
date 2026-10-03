import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_buttons_bridge_native.dart';
import 'package:player/core/window/window_buttons_hidden.dart';

void main() {
  group('shouldCallNativeButtonBridge', () {
    test('true hiding on windowed macOS', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: true,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test('true restoring on windowed macOS', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: false,
          isFullscreen: false,
        ),
        isTrue,
      );
    });

    test(
        'false hiding on fullscreen macOS — the OS already hides them '
        'there', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: true,
          isFullscreen: true,
        ),
        isFalse,
      );
    });

    test(
        'true restoring on fullscreen macOS — a restore is always safe to '
        'pass through, so the dispose() safety net still reaches native '
        'code even when the player is torn down while still fullscreen', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.macOS,
          hidden: false,
          isFullscreen: true,
        ),
        isTrue,
      );
    });

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('false hiding on ${platform.name} — no traffic lights there', () {
        expect(
          shouldCallNativeButtonBridge(
            platform: platform,
            hidden: true,
            isFullscreen: false,
          ),
          isFalse,
        );
      });

      test(
          'false restoring on ${platform.name} — no traffic lights there '
          'either', () {
        expect(
          shouldCallNativeButtonBridge(
            platform: platform,
            hidden: false,
            isFullscreen: false,
          ),
          isFalse,
        );
      });
    }

    test(
        'false on Linux, where the buttons are Flutter-drawn and the native '
        'bridge has nothing to hide', () {
      expect(
        shouldCallNativeButtonBridge(
          platform: TargetPlatform.linux,
          hidden: true,
          isFullscreen: false,
        ),
        isFalse,
      );
    });
  });

  group('publishWindowButtonsHidden', () {
    tearDown(() => windowButtonsHiddenSignal.value = false);

    testWidgets('a restore from dispose lands after the frame, not under it',
        (tester) async {
      windowButtonsHiddenSignal.value = true;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [
          ValueListenableBuilder<bool>(
            valueListenable: windowButtonsHidden,
            builder: (_, hidden, __) => Text('hidden: $hidden'),
          ),
          const _RestoresOnDispose(),
        ]),
      ));

      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Column(children: [
          ValueListenableBuilder<bool>(
            valueListenable: windowButtonsHidden,
            builder: (_, hidden, __) => Text('hidden: $hidden'),
          ),
        ]),
      ));
      expect(tester.takeException(), isNull);
      await tester.pump();

      expect(windowButtonsHiddenSignal.value, isFalse);
      expect(find.text('hidden: false'), findsOneWidget);
    });

    test('outside a frame the write is immediate', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      publishWindowButtonsHidden(true);
      expect(windowButtonsHiddenSignal.value, isTrue);
    });
  });
}

class _RestoresOnDispose extends StatefulWidget {
  const _RestoresOnDispose();

  @override
  State<_RestoresOnDispose> createState() => _RestoresOnDisposeState();
}

class _RestoresOnDisposeState extends State<_RestoresOnDispose> {
  @override
  void dispose() {
    publishWindowButtonsHidden(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
