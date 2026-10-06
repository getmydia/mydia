import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/remote_roster.dart' show DeviceRoster;
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/remote_device.dart';
import 'package:player/presentation/screens/settings/devices_controller.dart';

import '../sources/fake_media_source.dart';

RemoteDevice _device(String id, String name, {bool isRevoked = false}) =>
    RemoteDevice(
      id: id,
      deviceName: name,
      platform: 'linux',
      lastSeenAt: DateTime.utc(2026, 8, 20),
      isRevoked: isRevoked,
      createdAt: DateTime.utc(2026, 8, 1),
    );

/// One instance's device list, recording what is revoked on it.
class _Targets extends FakeMediaSource implements RemoteTargets {
  _Targets(SourceId id, this.name, {this.result = true}) : super(id: id);

  final String name;
  final bool result;
  final revoked = <String>[];
  var listCalls = 0;

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.remoteTargets};

  @override
  Future<List<RemoteDevice>> devices() async {
    listCalls += 1;
    return [_device('d1', name, isRevoked: revoked.contains('d1'))];
  }

  @override
  Future<bool> revokeDevice(String deviceId) async {
    if (result) revoked.add(deviceId);
    return result;
  }

  @override
  DeviceRoster get roster => throw UnimplementedError();

  @override
  Future<bool> registerNode(String nodeId) async => true;
}

void main() {
  const idA = SourceId('a:owner:inst');
  const idB = SourceId('b:owner:inst');
  late _Targets a;
  late _Targets b;
  late ProviderContainer container;

  setUp(() {
    a = _Targets(idA, 'Hall Screen');
    b = _Targets(idB, 'Attic Tablet');
    container = ProviderContainer(retry: (_, __) => null, overrides: [
      mediaSourceProvider.overrideWith((ref, id) => switch (id) {
            idA => a,
            idB => b,
            _ => null,
          }),
    ]);
    addTearDown(container.dispose);
  });

  test('lists the devices of the instance it is asked about', () async {
    final devices = await container.read(devicesControllerProvider(idA).future);

    expect(devices.single.deviceName, 'Hall Screen');
    expect(
        (await container.read(devicesControllerProvider(idB).future))
            .single
            .deviceName,
        'Attic Tablet');
  });

  test('fails when the instance has no source', () async {
    await expectLater(
      container.read(devicesControllerProvider(const SourceId('x')).future),
      throwsA(isA<Exception>()),
    );
  });

  test('revoking on A calls only A and leaves B\'s list alone', () async {
    await container.read(devicesControllerProvider(idA).future);
    await container.read(devicesControllerProvider(idB).future);

    final ok = await container
        .read(devicesControllerProvider(idA).notifier)
        .revokeDevice('d1');

    expect(ok, isTrue);
    expect(a.revoked, ['d1']);
    expect(b.revoked, isEmpty);
    expect(a.listCalls, 2, reason: 'a successful revoke refreshes A');
    expect(b.listCalls, 1);
    expect(
        container.read(devicesControllerProvider(idA)).value!.single.isRevoked,
        isTrue);
    expect(
        container.read(devicesControllerProvider(idB)).value!.single.isRevoked,
        isFalse);
  });

  test('a refused revoke reports false and does not reload', () async {
    a = _Targets(idA, 'Hall Screen', result: false);
    await container.read(devicesControllerProvider(idA).future);

    final ok = await container
        .read(devicesControllerProvider(idA).notifier)
        .revokeDevice('d1');

    expect(ok, isFalse);
    expect(a.listCalls, 1);
  });
}
