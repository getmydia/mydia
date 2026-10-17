import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/system_accent.dart';

const _name = 'test/system-accent';
const _channel = MethodChannel(_name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> fromNative(String method, Object? arguments) =>
      messenger.handlePlatformMessage(
        _name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      nativeTabBarChannelProvider
          .overrideWith((ref) => NativeTabBarChannel(channel: _channel)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  tearDown(() {
    SystemAccent.debugIsNativeMacOS = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('off macOS it is the default accent and never asks native', () async {
    SystemAccent.debugIsNativeMacOS = false;
    var asked = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      asked = true;
      return 0xFFFF453A;
    });
    final c = container();
    expect(c.read(systemAccentProvider), Palettes.macosDefaultAccent);
    await Future<void>.delayed(Duration.zero);
    expect(asked, isFalse);
  });

  test('on macOS it takes the queried accent, then follows changes', () async {
    SystemAccent.debugIsNativeMacOS = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return call.method == 'systemAccent' ? 0xFF30D158 : null;
    });
    final c = container();
    final sub = c.listen(systemAccentProvider, (_, __) {});
    addTearDown(sub.close);
    expect(c.read(systemAccentProvider), Palettes.macosDefaultAccent);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(systemAccentProvider), const Color(0xFF30D158));

    await fromNative('systemAccentChanged', 0xFFBF5AF2);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(systemAccentProvider), const Color(0xFFBF5AF2));

    await fromNative('systemAccentChanged', 'nonsense');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(systemAccentProvider), const Color(0xFFBF5AF2));
  });
}
