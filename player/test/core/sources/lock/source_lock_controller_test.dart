import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/lock/device_auth.dart';
import 'package:player/core/sources/lock/pin_store.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _Auth implements DeviceAuth {
  _Auth(this.result);
  DeviceAuthResult result;
  @override
  Future<bool> available() async => result != DeviceAuthResult.unavailable;
  @override
  Future<DeviceAuthResult> authenticate() async => result;
}

ProviderContainer _container(DeviceAuthResult result, {PinStore? pins}) {
  final c = ProviderContainer(overrides: [
    deviceAuthProvider.overrideWithValue(_Auth(result)),
    pinStoreProvider.overrideWithValue(
        pins ?? PinStore(MockAuthStorage(), iterations: 1000)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('starts locked', () {
    expect(
        _container(DeviceAuthResult.success).read(sourceLockProvider), isFalse);
  });

  test('device success unlocks; cancel and failure do not', () async {
    final ok = _container(DeviceAuthResult.success);
    expect(await ok.read(sourceLockProvider.notifier).unlockWithDevice(),
        DeviceAuthResult.success);
    expect(ok.read(sourceLockProvider), isTrue);

    final no = _container(DeviceAuthResult.cancelled);
    await no.read(sourceLockProvider.notifier).unlockWithDevice();
    expect(no.read(sourceLockProvider), isFalse);
  });

  test('the right PIN unlocks', () async {
    final pins = PinStore(MockAuthStorage(), iterations: 1000);
    await pins.setPin('4821');
    final c = _container(DeviceAuthResult.unavailable, pins: pins);
    expect(await c.read(sourceLockProvider.notifier).unlockWithPin('0000'),
        isA<PinRejected>());
    expect(c.read(sourceLockProvider), isFalse);
    expect(await c.read(sourceLockProvider.notifier).unlockWithPin('4821'),
        isA<PinAccepted>());
    expect(c.read(sourceLockProvider), isTrue);
  });

  test('relocks a minute after going to the background', () {
    fakeAsync((async) {
      final c = _container(DeviceAuthResult.success);
      final lock = c.read(sourceLockProvider.notifier);
      lock.unlockWithDevice();
      async.flushMicrotasks();
      lock.onLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(seconds: 59));
      expect(c.read(sourceLockProvider), isTrue);
      async.elapse(const Duration(seconds: 2));
      expect(c.read(sourceLockProvider), isFalse);
    });
  });

  test('coming back within the minute keeps it unlocked', () {
    fakeAsync((async) {
      final c = _container(DeviceAuthResult.success);
      final lock = c.read(sourceLockProvider.notifier);
      lock.unlockWithDevice();
      async.flushMicrotasks();
      lock.onLifecycle(AppLifecycleState.hidden);
      async.elapse(const Duration(seconds: 30));
      lock.onLifecycle(AppLifecycleState.resumed);
      async.elapse(const Duration(minutes: 5));
      expect(c.read(sourceLockProvider), isTrue);
    });
  });

  test('a hold defers the relock until released', () {
    fakeAsync((async) {
      final c = _container(DeviceAuthResult.success);
      final lock = c.read(sourceLockProvider.notifier);
      lock.unlockWithDevice();
      async.flushMicrotasks();
      final release = lock.hold();
      expect(lock.holding, isTrue);
      lock.onLifecycle(AppLifecycleState.paused);
      async.elapse(const Duration(minutes: 10));
      expect(c.read(sourceLockProvider), isTrue);
      release();
      release(); // idempotent
      expect(lock.holding, isFalse);
      expect(c.read(sourceLockProvider), isFalse);
    });
  });

  test('lock() locks at once', () async {
    final c = _container(DeviceAuthResult.success);
    await c.read(sourceLockProvider.notifier).unlockWithDevice();
    c.read(sourceLockProvider.notifier).lock();
    expect(c.read(sourceLockProvider), isFalse);
  });

  test('unlockLocation encodes the destination', () {
    expect(unlockLocation('/a?b=1'), '/unlock?next=%2Fa%3Fb%3D1');
  });
}
