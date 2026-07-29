import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/domain/models/cast_device.dart';

const _device = CastDevice(
  id: 'device-1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

const _other = CastDevice(
  id: 'device-2',
  name: 'Bedroom TV',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  group('castTargetProvider', () {
    test('starts with no target', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(castTargetProvider), isNull);
    });

    test('set records the device', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(castTargetProvider.notifier).set(_device);

      expect(container.read(castTargetProvider), _device);
    });

    test('set replaces a previous target', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(castTargetProvider.notifier).set(_device);
      container.read(castTargetProvider.notifier).set(_other);

      expect(container.read(castTargetProvider), _other);
    });

    test('clear removes the target', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(castTargetProvider.notifier).set(_device);
      container.read(castTargetProvider.notifier).clear();

      expect(container.read(castTargetProvider), isNull);
    });
  });
}
