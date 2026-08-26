import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/core/window/decoration_layout_source_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mydia.player/window_chrome');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Answers `getDecorationLayout` with [layout], or throws if it is null.
  void stubChannel(String? layout) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getDecorationLayout') return null;
      if (layout == null) {
        throw PlatformException(code: 'unavailable');
      }
      return layout;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('DecorationLayoutSource', () {
    test('starts on the fallback before load() is awaited', () {
      stubChannel('appmenu:close');
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);

      expect(source.layout.value,
          parseDecorationLayout(kFallbackDecorationLayout));
    });

    test('publishes what the channel reports', () async {
      stubChannel('appmenu:close');
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);

      await source.load();

      expect(source.layout.value.start, isEmpty);
      expect(source.layout.value.end, [WindowButton.close]);
    });

    test('keeps the fallback when the channel throws, and does not rethrow',
        () async {
      stubChannel(null);
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);

      await source.load();

      expect(
        source.layout.value,
        parseDecorationLayout(kFallbackDecorationLayout),
      );
    });

    test('keeps the fallback when the channel returns an empty string',
        () async {
      stubChannel('');
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);

      await source.load();

      expect(
        source.layout.value,
        parseDecorationLayout(kFallbackDecorationLayout),
      );
    });

    test('notifies listeners when GTK pushes a changed layout', () async {
      stubChannel('appmenu:close');
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);
      await source.load();

      var notifications = 0;
      source.layout.addListener(() => notifications++);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onDecorationLayoutChanged', 'close:minimize'),
        ),
        (_) {},
      );

      expect(notifications, 1);
      expect(source.layout.value.start, [WindowButton.close]);
      expect(source.layout.value.end, [WindowButton.minimize]);
    });

    test(
        'does not notify when the pushed layout parses to the same value, so '
        'an unrelated GTK settings churn cannot rebuild the chrome', () async {
      stubChannel('appmenu:close');
      final source = DecorationLayoutSource();
      addTearDown(source.dispose);
      await source.load();

      var notifications = 0;
      source.layout.addListener(() => notifications++);

      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          // Different string, identical parse: `icon` and `appmenu` both drop.
          const MethodCall('onDecorationLayoutChanged', 'icon:close'),
        ),
        (_) {},
      );

      expect(notifications, 0);
    });
  });
}
