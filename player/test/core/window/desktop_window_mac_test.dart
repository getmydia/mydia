import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/desktop_window.dart';
import 'package:player/core/window/window_chrome_channel.dart';

/// macOS drives the window through `WindowPlugin`'s channel, because nativeapi
/// cannot reach the window from Dart's off-main thread there. Separate from
/// `desktop_window_test.dart`, which deliberately runs with no binding.
///
/// The order matters: `initDesktopWindow` keeps module state, so the case
/// where the window cannot be reached runs before the one that reaches it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kMacWindowChannelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answerEveryCall() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isFullScreen':
        case 'isMaximized':
          return false;
        case 'getBounds':
          return {'x': 100.0, 'y': 100.0, 'width': 1280.0, 'height': 800.0};
        case 'getWorkAreas':
          return [
            {
              'x': 0.0,
              'y': 0.0,
              'width': 1440.0,
              'height': 875.0,
              'isPrimary': true,
            },
          ];
      }
      return null;
    });
  }

  setUp(() {
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('with no Runner handler, every entry point completes', () async {
    // No mock: every call fails with MissingPluginException.
    await expectLater(initDesktopWindow(), completes);
    expect(startWindowDrag, returnsNormally);
    expect(() => setWindowAlwaysOnTop(true), returnsNormally);
    await expectLater(raiseDesktopWindow(), completes);
    await pumpEventQueue();
  });

  test('initDesktopWindow asks the channel, not nativeapi', () async {
    answerEveryCall();

    await initDesktopWindow();

    expect(
      calls.map((c) => c.method),
      containsAll(['isFullScreen', 'isMaximized']),
    );
  });

  test('setWindowAlwaysOnTop sends {value}', () async {
    answerEveryCall();

    setWindowAlwaysOnTop(true);
    await pumpEventQueue();

    expect(calls.last.method, 'setAlwaysOnTop');
    expect(calls.last.arguments, {'value': true});
  });

  test(
    'startWindowDrag and raiseDesktopWindow go through the channel',
    () async {
      answerEveryCall();

      startWindowDrag();
      await raiseDesktopWindow();
      await pumpEventQueue();

      expect(
        calls.map((c) => c.method),
        containsAll(['startDragging', 'raise']),
      );
    },
  );
}
