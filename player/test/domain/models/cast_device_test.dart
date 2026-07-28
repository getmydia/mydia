import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  group('CastDevice', () {
    const device = CastDevice(
      id: 'abc123',
      name: 'Living Room TV',
      protocol: CastProtocolKind.chromecast,
      model: 'Chromecast Ultra',
      host: '192.168.1.50',
      port: 8009,
    );

    test('round-trips through JSON', () {
      final restored = CastDevice.fromJson(device.toJson());

      expect(restored.id, device.id);
      expect(restored.name, device.name);
      expect(restored.protocol, CastProtocolKind.chromecast);
      expect(restored.model, device.model);
      expect(restored.host, device.host);
      expect(restored.port, device.port);
    });

    test('round-trips a DLNA device', () {
      const dlna = CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
      );

      expect(CastDevice.fromJson(dlna.toJson()).protocol, CastProtocolKind.dlna);
    });

    test('falls back to chromecast for an unknown protocol string', () {
      final restored = CastDevice.fromJson(const {
        'id': 'x',
        'name': 'y',
        'protocol': 'satellite',
      });

      expect(restored.protocol, CastProtocolKind.chromecast);
    });

    test('equality is by id', () {
      const other = CastDevice(
        id: 'abc123',
        name: 'Renamed',
        protocol: CastProtocolKind.dlna,
      );

      expect(device, equals(other));
    });
  });
}
