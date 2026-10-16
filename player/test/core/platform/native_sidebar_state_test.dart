import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_sidebar_state.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';

const _name = 'test/native-sidebar-state';
const _channel = MethodChannel(_name);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> fromNative(String method, Object? arguments) async {
    await messenger.handlePlatformMessage(
      _name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  ProviderContainer containerAnswering(Object? layout) {
    messenger.setMockMethodCallHandler(
        _channel, (call) async => call.method == 'layout' ? layout : null);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final container = ProviderContainer(overrides: [
      nativeTabBarChannelProvider.overrideWith((ref) {
        final channel = NativeTabBarChannel(channel: _channel);
        ref.onDispose(channel.dispose);
        return channel;
      }),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('insets keep a chrome-only report', () async {
    final container = containerAnswering(null);
    container.read(nativeSidebarInsetsProvider);
    await fromNative('insetsChanged',
        {'top': 0.0, 'leading': 0.0, 'bottom': 0.0, 'chromeLeading': 124.0});
    expect(container.read(nativeSidebarInsetsProvider),
        const NativeInsets(chromeLeading: 124, reportsChrome: true));
  });

  test('a later chromeLeading 0 report replaces a collapsed one', () async {
    final container = containerAnswering(null);
    container.read(nativeSidebarInsetsProvider);
    await fromNative('insetsChanged',
        {'top': 0.0, 'leading': 0.0, 'bottom': 0.0, 'chromeLeading': 124.0});
    await fromNative('insetsChanged',
        {'top': 0.0, 'leading': 0.0, 'bottom': 0.0, 'chromeLeading': 0.0});
    expect(container.read(nativeSidebarInsetsProvider)?.chromeLeading, 0);
  });

  test('an all-zero report without the key is still dropped', () async {
    final container = containerAnswering(null);
    container.read(nativeSidebarInsetsProvider);
    await fromNative(
        'insetsChanged', {'top': 0.0, 'leading': 300.0, 'bottom': 0.0});
    await fromNative(
        'insetsChanged', {'top': 0.0, 'leading': 0.0, 'bottom': 0.0});
    expect(container.read(nativeSidebarInsetsProvider)?.leading, 300);
  });

  test('regular starts true and takes the queried layout', () async {
    final container = containerAnswering({'sidebar': false});
    expect(container.read(nativeSidebarRegularProvider), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(nativeSidebarRegularProvider), isFalse);
  });

  test('regular follows layoutChanged', () async {
    final container = containerAnswering(null);
    container.read(nativeSidebarRegularProvider);
    await fromNative('layoutChanged', {'sidebar': false});
    expect(container.read(nativeSidebarRegularProvider), isFalse);
    await fromNative('layoutChanged', {'sidebar': true});
    expect(container.read(nativeSidebarRegularProvider), isTrue);
  });

  test('a late layout answer does not overwrite a layoutChanged event',
      () async {
    final answer = Completer<Object?>();
    messenger.setMockMethodCallHandler(
        _channel, (call) => call.method == 'layout' ? answer.future : null);
    addTearDown(() => messenger.setMockMethodCallHandler(_channel, null));
    final container = ProviderContainer(overrides: [
      nativeTabBarChannelProvider.overrideWith((ref) {
        final channel = NativeTabBarChannel(channel: _channel);
        ref.onDispose(channel.dispose);
        return channel;
      }),
    ]);
    addTearDown(container.dispose);
    container.read(nativeSidebarRegularProvider);
    await fromNative('layoutChanged', {'sidebar': false});
    answer.complete({'sidebar': true});
    await Future<void>.delayed(Duration.zero);
    expect(container.read(nativeSidebarRegularProvider), isFalse);
  });

  test('insets keep the last non-zero report', () async {
    final container = containerAnswering(null);
    expect(container.read(nativeSidebarInsetsProvider), isNull);
    await fromNative(
        'insetsChanged', {'top': 24.0, 'leading': 320.0, 'bottom': 0.0});
    await fromNative(
        'insetsChanged', {'top': 0.0, 'leading': 0.0, 'bottom': 0.0});
    expect(container.read(nativeSidebarInsetsProvider),
        const NativeInsets(top: 24, leading: 320));
  });
}
