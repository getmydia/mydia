import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/window_frame_state.dart';
import 'package:player/core/window/window_frame_state_source_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mydia.player/window_frame');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Answers `getWindowState` with [state], or throws if it is null.
  void stubChannel(Map<String, bool>? state) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getWindowState') return null;
      if (state == null) throw PlatformException(code: 'unavailable');
      return state;
    });
  }

  Future<void> push(Map<String, bool> state) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('onWindowStateChanged', state),
        ),
        (_) {},
      );

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('WindowFrameStateSource', () {
    test('starts floating before load() is awaited', () {
      stubChannel({'maximized': true});
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);

      expect(source.state.value, WindowFrameState.floating);
    });

    test('publishes what the channel reports', () async {
      stubChannel({'maximized': true, 'tiled': false, 'fullscreen': false});
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);

      await source.load();

      expect(source.state.value, const WindowFrameState(maximized: true));
    });

    test('stays floating when the channel throws, and does not rethrow',
        () async {
      stubChannel(null);
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);

      await source.load();

      expect(source.state.value, WindowFrameState.floating);
    });

    test('follows pushed changes', () async {
      stubChannel({});
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);
      await source.load();

      await push({'maximized': false, 'tiled': true, 'fullscreen': false});

      expect(source.state.value, const WindowFrameState(tiled: true));
    });

    test('follows a pushed solidFrame change', () async {
      stubChannel({});
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);
      await source.load();

      await push({
        'maximized': false,
        'tiled': false,
        'fullscreen': false,
        'solidFrame': true,
      });

      expect(source.state.value, const WindowFrameState(solidFrame: true));
    });

    test('a state pushed mid-load survives the older read landing after it',
        () async {
      final gate = Completer<Map<String, bool>>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'getWindowState') return null;
        return gate.future;
      });
      final source = WindowFrameStateSource();
      addTearDown(source.dispose);

      final pending = source.load();
      await push({'maximized': false, 'tiled': true, 'fullscreen': false});
      gate.complete({'maximized': true});
      await pending;

      expect(source.state.value, const WindowFrameState(tiled: true),
          reason: 'the superseded startup read overwrote a newer pushed '
              'state, leaving the clip wrong until the window changed again');
    });
  });
}
