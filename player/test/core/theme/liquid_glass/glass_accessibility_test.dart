import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/theme/liquid_glass/glass_accessibility.dart';

const _name = 'test/glass-accessibility';
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

  // The listener asserts on skipped states, so walk the real sequence.
  void suspendAndResume() {
    final binding = TestWidgetsFlutterBinding.instance;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
  }

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      nativeTabBarChannelProvider
          .overrideWith((ref) => NativeTabBarChannel(channel: _channel)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  tearDown(() {
    GlassAccessibilityNotifier.debugIsApple = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test('fromChannel parses the map and rejects anything else', () {
    expect(
      GlassAccessibility.fromChannel(
          {'reduceTransparency': true, 'increaseContrast': false}),
      const GlassAccessibility(reduceTransparency: true),
    );
    expect(GlassAccessibility.fromChannel(null), isNull);
    expect(GlassAccessibility.fromChannel('nope'), isNull);
  });

  test('off Apple it is none and never asks native', () async {
    GlassAccessibilityNotifier.debugIsApple = false;
    var asked = false;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      asked = true;
      return null;
    });
    final c = container();
    expect(c.read(glassAccessibilityProvider), GlassAccessibility.none);
    await Future<void>.delayed(Duration.zero);
    expect(asked, isFalse);

    suspendAndResume();
    await Future<void>.delayed(Duration.zero);
    expect(asked, isFalse);
  });

  test('on Apple it re-reads the flags when the app resumes', () async {
    GlassAccessibilityNotifier.debugIsApple = true;
    var answer = {'reduceTransparency': false, 'increaseContrast': true};
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return call.method == 'glassAccessibility' ? answer : null;
    });
    final c = container();
    final sub = c.listen(glassAccessibilityProvider, (_, __) {});
    addTearDown(sub.close);
    c.read(glassAccessibilityProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(glassAccessibilityProvider),
        const GlassAccessibility(increaseContrast: true));

    answer = {'reduceTransparency': true, 'increaseContrast': false};
    suspendAndResume();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(glassAccessibilityProvider),
        const GlassAccessibility(reduceTransparency: true));
  });

  test('on Apple it takes the queried flags, then follows pushes', () async {
    GlassAccessibilityNotifier.debugIsApple = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      return call.method == 'glassAccessibility'
          ? {'reduceTransparency': false, 'increaseContrast': true}
          : null;
    });
    final c = container();
    final sub = c.listen(glassAccessibilityProvider, (_, __) {});
    addTearDown(sub.close);
    expect(c.read(glassAccessibilityProvider), GlassAccessibility.none);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(glassAccessibilityProvider),
        const GlassAccessibility(increaseContrast: true));

    await fromNative('glassAccessibilityChanged',
        {'reduceTransparency': true, 'increaseContrast': true});
    expect(
      c.read(glassAccessibilityProvider),
      const GlassAccessibility(
          reduceTransparency: true, increaseContrast: true),
    );
  });

  testWidgets('the scope defaults to none', (tester) async {
    late GlassAccessibility seen;
    await tester.pumpWidget(Builder(builder: (context) {
      seen = GlassAccessibilityScope.of(context);
      return const SizedBox();
    }));
    expect(seen, GlassAccessibility.none);
  });
}
