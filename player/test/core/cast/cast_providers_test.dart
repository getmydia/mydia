import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/domain/models/cast_device.dart';

import '../../test_utils/fake_cast_backend.dart';

void main() {
  late FakeCastBackend backend;

  ProviderContainer buildContainer() {
    final container = ProviderContainer(overrides: [
      castBackendProvider.overrideWithValue(backend),
      castCapabilitiesProvider
          .overrideWithValue(const CastCapabilities.full()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => backend = FakeCastBackend());

  test('castDiscoveryProvider starts discovery on first listen', () async {
    final container = buildContainer();

    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    expect(backend.discoveryStarted, isTrue);
  });

  test('castDiscoveryProvider surfaces discovered devices', () async {
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    addTearDown(sub.close);
    await Future<void>.delayed(Duration.zero);

    backend.emitDevices(const [
      CastDevice(id: 'd1', name: 'TV', protocol: CastProtocolKind.chromecast),
    ]);
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(castDiscoveryProvider).value?.single.name,
      'TV',
    );
  });

  test('castDiscoveryProvider stops discovery when no longer listened to',
      () async {
    final container = buildContainer();
    final sub = container.listen(castDiscoveryProvider, (_, __) {});
    await Future<void>.delayed(Duration.zero);

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(backend.discoveryStopped, isTrue);
  });

  test('castCapabilitiesProvider yields no capability on web builds', () {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.web()),
    ]);
    addTearDown(container.dispose);

    expect(container.read(castCapabilitiesProvider).any, isFalse);
  });
}
