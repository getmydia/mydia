import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/fullscreen/fullscreen_backend_native.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';

void main() {
  group('NativeFullscreenBackend', () {
    test(
        'on Windows, enter and exit update state and window signal optimistically',
        () {
      final changes = <bool>[];
      final windowSignal = ValueNotifier<bool>(false);
      var nativeEnterCalls = 0;
      var nativeExitCalls = 0;

      final backend = NativeFullscreenBackend(
        onChange: changes.add,
        windowSignal: windowSignal,
        isWindows: true,
        onEnterNative: () => nativeEnterCalls++,
        onExitNative: () => nativeExitCalls++,
      );
      addTearDown(backend.dispose);

      expect(backend.mode, FullscreenMode.osWindow);

      backend.enter();
      expect(nativeEnterCalls, 1);
      expect(windowSignal.value, isTrue);
      expect(changes, [true]);

      backend.exit();
      expect(nativeExitCalls, 1);
      expect(windowSignal.value, isFalse);
      expect(changes, [true, false]);
    });

    test(
        'on Windows with player attached, each transition reports exactly once',
        () {
      final changes = <bool>[];
      final windowSignal = ValueNotifier<bool>(false);
      var nativeEnterCalls = 0;
      var nativeExitCalls = 0;

      final backend = NativeFullscreenBackend(
        onChange: changes.add,
        windowSignal: windowSignal,
        isWindows: true,
        onEnterNative: () => nativeEnterCalls++,
        onExitNative: () => nativeExitCalls++,
      );
      addTearDown(backend.dispose);

      final player = Player(platformPlayer: _FakePlatformPlayer());
      backend.attach(player);
      // attach initial republish
      expect(changes, [false]);

      backend.enter();
      expect(nativeEnterCalls, 1);
      expect(windowSignal.value, isTrue);
      // exactly once for enter (republished via windowSignal)
      expect(changes, [false, true]);

      backend.exit();
      expect(nativeExitCalls, 1);
      expect(windowSignal.value, isFalse);
      // exactly once for exit (republished via windowSignal)
      expect(changes, [false, true, false]);
    });

    test('on non-Windows desktop, enter does not optimistically report', () {
      final changes = <bool>[];
      final windowSignal = ValueNotifier<bool>(false);
      var nativeEnterCalls = 0;

      final backend = NativeFullscreenBackend(
        onChange: changes.add,
        windowSignal: windowSignal,
        isWindows: false,
        onEnterNative: () => nativeEnterCalls++,
      );
      addTearDown(backend.dispose);

      backend.enter();
      expect(nativeEnterCalls, 1);
      // Non-Windows desktop waits for the OS event through windowFullscreen
      expect(changes, isEmpty);
      expect(windowSignal.value, isFalse);
    });

    test('attach listens to windowSignal and republishes state', () {
      final changes = <bool>[];
      final windowSignal = ValueNotifier<bool>(false);

      final backend = NativeFullscreenBackend(
        onChange: changes.add,
        windowSignal: windowSignal,
        isWindows: false,
        onEnterNative: () {},
        onExitNative: () {},
      );
      addTearDown(backend.dispose);

      final player = Player(platformPlayer: _FakePlatformPlayer());
      backend.attach(player);

      expect(changes, [false]);

      windowSignal.value = true;
      expect(changes, [false, true]);

      windowSignal.value = false;
      expect(changes, [false, true, false]);
    });

    test('dispose removes listener from windowSignal', () {
      final changes = <bool>[];
      final windowSignal = ValueNotifier<bool>(false);

      final backend = NativeFullscreenBackend(
        onChange: changes.add,
        windowSignal: windowSignal,
        isWindows: false,
        onEnterNative: () {},
        onExitNative: () {},
      );

      final player = Player(platformPlayer: _FakePlatformPlayer());
      backend.attach(player);
      expect(changes, [false]);

      backend.dispose();

      windowSignal.value = true;
      // Should not have received the update after dispose
      expect(changes, [false]);
    });
  });
}

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}
