import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/multicast_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.mydia.player/test-multicast');
  late List<String> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('MulticastLock on Android', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('acquire and release reach the host', () async {
      const lock = MulticastLock(channel: channel);

      await lock.acquire();
      await lock.release();

      expect(calls, ['acquireMulticastLock', 'releaseMulticastLock']);
    });

    test('a host-side failure never propagates to the picker', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'boom');
      });

      const lock = MulticastLock(channel: channel);

      await expectLater(lock.acquire(), completes);
    });
  });

  test('is a no-op off Android, where no such lock exists', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    const lock = MulticastLock(channel: channel);

    expect(lock.isSupported, isFalse);
    await lock.acquire();
    await lock.release();

    expect(calls, isEmpty);
  });
}
