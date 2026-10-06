import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/settings/devices_controller.dart';

import '../../../core/sources/mydia/fake_mydia_client.dart';
import '../../../core/sources/mydia/fake_mydia_transport.dart';

Map<String, dynamic> _device(String id, String name,
        {bool isRevoked = false}) =>
    {
      '__typename': 'RemoteDevice',
      'id': id,
      'deviceName': name,
      'platform': 'linux',
      'lastSeenAt': '2026-08-20T12:00:00Z',
      'isRevoked': isRevoked,
      'createdAt': '2026-08-01T12:00:00Z',
    };

Map<String, dynamic> _list(List<Map<String, dynamic>> devices) =>
    {'__typename': 'RootQueryType', 'devices': devices};

Map<String, dynamic> _revoked({required bool success}) => {
      '__typename': 'RootMutationType',
      'revokeDevice': {
        '__typename': 'RevokeDeviceResult',
        'success': success,
        'device': _device('d1', 'Hall Screen', isRevoked: success),
      },
    };

void main() {
  late FakeMydiaTransport server;
  late ProviderContainer container;

  ProviderContainer containerFor(FakeMydiaTransport transport) {
    final c = ProviderContainer(retry: (_, __) => null, overrides: [
      boundMydiaClientProvider.overrideWithValue(fakeMydiaClient(transport)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    server = FakeMydiaTransport();
    container = containerFor(server);
  });

  test('lists the devices the server reports', () async {
    server.handlers['DevicesList'] = (_) => _list([
          _device('d1', 'Hall Screen'),
          _device('d2', 'Attic Tablet'),
        ]);

    final devices = await container.read(devicesControllerProvider.future);

    expect(devices.map((d) => d.id), ['d1', 'd2']);
    expect(devices.first.deviceName, 'Hall Screen');
  });

  test('fails with the server\'s words when the list is refused', () async {
    server.handlers['DevicesList'] =
        (_) => throw const SourceException.server('boom');

    await expectLater(
      container.read(devicesControllerProvider.future),
      throwsA(isA<SourceException>()),
    );
  });

  test('fails when no server is bound', () async {
    final unbound = ProviderContainer(retry: (_, __) => null, overrides: [
      boundMydiaClientProvider.overrideWithValue(null),
    ]);
    addTearDown(unbound.dispose);

    await expectLater(
      unbound.read(devicesControllerProvider.future),
      throwsA(isA<Exception>()),
    );
  });

  test('revoking sends the id, then reloads the list', () async {
    var revoked = false;
    server.handlers['DevicesList'] = (_) => _list([
          _device('d1', 'Hall Screen', isRevoked: revoked),
        ]);
    server.handlers['RevokeDevice'] = (_) {
      revoked = true;
      return _revoked(success: true);
    };
    await container.read(devicesControllerProvider.future);

    final ok =
        await container.read(devicesControllerProvider.notifier).revokeDevice(
              'd1',
            );

    expect(ok, isTrue);
    final revoke =
        server.calls.singleWhere((c) => c.operation == 'RevokeDevice');
    expect(revoke.vars, {'id': 'd1'});
    expect(
        server.calls.where((c) => c.operation == 'DevicesList'), hasLength(2),
        reason: 'a successful revoke refreshes the list');
    expect(container.read(devicesControllerProvider).value!.single.isRevoked,
        isTrue);
  });

  test('a refused revoke reports false and leaves the list alone', () async {
    server.handlers['DevicesList'] = (_) => _list([_device('d1', 'Hall')]);
    server.handlers['RevokeDevice'] = (_) => _revoked(success: false);
    await container.read(devicesControllerProvider.future);

    final ok = await container
        .read(devicesControllerProvider.notifier)
        .revokeDevice('d1');

    expect(ok, isFalse);
    expect(
        server.calls.where((c) => c.operation == 'DevicesList'), hasLength(1));
  });
}
