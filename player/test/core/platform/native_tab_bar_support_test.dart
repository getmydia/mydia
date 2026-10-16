import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_tab_bar_support.dart';

void main() {
  late List<MethodCall> calls;

  void answer(Future<Object?> Function() reply) {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeTabBarSupport.channel, (call) {
      calls.add(call);
      return reply();
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeTabBarSupport.channel, null);
    debugDefaultTargetPlatformOverride = null;
    NativeTabBarSupport.debugOverride = null;
    NativeTabBarSupport.debugOverrideMode = null;
    NativeTabBarSupport.debugReset();
  });

  testWidgets('never initialized: unsupported', (tester) async {
    expect(NativeTabBarSupport.supported, isFalse);
  });

  testWidgets('off iOS: unsupported without touching the channel',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    answer(() async => true);
    await NativeTabBarSupport.initialize();
    expect(NativeTabBarSupport.supported, isFalse);
    expect(calls, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS answering bar: supported', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    answer(() async => 'bar');
    await NativeTabBarSupport.initialize();
    expect(NativeTabBarSupport.supported, isTrue);
    expect(NativeTabBarSupport.mode, NativeTabBarMode.bar);
    expect(calls.single.method, 'mode');
    debugDefaultTargetPlatformOverride = null;
  });

  for (final (name, reply) in <(String, Future<Object?> Function())>[
    ('false', () async => false),
    ('banana', () async => 'banana'),
    ('none', () async => 'none'),
    ('null', () async => null),
    ('a PlatformException', () async => throw PlatformException(code: 'x')),
  ]) {
    testWidgets('iOS answering $name: unsupported', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      answer(reply);
      await NativeTabBarSupport.initialize();
      expect(NativeTabBarSupport.supported, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('iOS with no plugin: unsupported', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // An unregistered channel never replies under the test binding, so the
    // handler throws what a real engine without the plugin would.
    answer(() async => throw MissingPluginException());
    await NativeTabBarSupport.initialize();
    expect(NativeTabBarSupport.supported, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS never answering: unsupported after the timeout',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    answer(() => Completer<Object?>().future);
    var done = false;
    unawaited(NativeTabBarSupport.initialize().then((_) => done = true));
    await tester.pump(const Duration(seconds: 1));
    expect(done, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue);
    expect(NativeTabBarSupport.supported, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('debugOverride wins', (tester) async {
    NativeTabBarSupport.debugOverride = true;
    expect(NativeTabBarSupport.supported, isTrue);
  });

  testWidgets('mode answers sidebar on an iPad', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    answer(() async => 'sidebar');
    await NativeTabBarSupport.initialize();
    expect(NativeTabBarSupport.mode, NativeTabBarMode.sidebar);
    expect(NativeTabBarSupport.supported, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  test('debugOverride true still means the bar', () {
    NativeTabBarSupport.debugOverride = true;
    expect(NativeTabBarSupport.mode, NativeTabBarMode.bar);
  });

  test('debugOverrideMode wins', () {
    NativeTabBarSupport.debugOverrideMode = NativeTabBarMode.sidebar;
    expect(NativeTabBarSupport.mode, NativeTabBarMode.sidebar);
  });
}
