import 'dart:io';

import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/bonsoir_chromecast_discovery.dart';
import 'package:player/core/cast/dart_cast_backend.dart';
import 'package:player/domain/models/cast_device.dart';

void main() {
  group('chromecastDeviceFromBonsoir', () {
    test('maps a resolved Bonsoir service to a dart_cast device', () {
      final device = chromecastDeviceFromBonsoir(const {
        'service.name': 'Living Room',
        'service.port': 8009,
        'service.hostAddresses': ['192.168.1.50'],
        'service.attributes': {'md': 'Chromecast Ultra', 'id': 'abc123'},
      });

      expect(device, isNotNull);
      expect(device!.name, 'Living Room');
      expect(device.port, 8009);
      expect(device.address.address, '192.168.1.50');
      expect(device.protocol, dc.CastProtocol.chromecast);
      expect(device.metadata['md'], 'Chromecast Ultra');
    });

    test('prefers the friendly name attribute when present', () {
      final device = chromecastDeviceFromBonsoir(const {
        'service.name': 'Chromecast-abc123',
        'service.port': 8009,
        'service.hostAddresses': ['192.168.1.50'],
        'service.attributes': {'fn': 'Kitchen Display'},
      });

      expect(device!.name, 'Kitchen Display');
    });

    test('returns null when the service has no resolved address', () {
      final device = chromecastDeviceFromBonsoir(const {
        'service.name': 'Living Room',
        'service.port': 8009,
        'service.hostAddresses': <String>[],
      });

      expect(device, isNull);
    });

    test('returns null when the port is missing', () {
      final device = chromecastDeviceFromBonsoir(const {
        'service.name': 'Living Room',
        'service.hostAddresses': ['192.168.1.50'],
      });

      expect(device, isNull);
    });
  });

  group('toDomainDevice', () {
    test('maps a Chromecast device', () {
      final domain = toDomainDevice(dc.CastDevice(
        id: 'abc',
        name: 'Living Room',
        protocol: dc.CastProtocol.chromecast,
        address: InternetAddress('192.168.1.50'),
        port: 8009,
        metadata: const {'md': 'Chromecast Ultra'},
      ));

      expect(domain.id, 'abc');
      expect(domain.protocol, CastProtocolKind.chromecast);
      expect(domain.model, 'Chromecast Ultra');
      expect(domain.host, '192.168.1.50');
      expect(domain.port, 8009);
    });

    test('maps a DLNA device', () {
      final domain = toDomainDevice(dc.CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: dc.CastProtocol.dlna,
        address: InternetAddress('192.168.1.51'),
        port: 1900,
      ));

      expect(domain.protocol, CastProtocolKind.dlna);
      expect(domain.model, isNull);
    });
  });

  group('playbackStateFrom', () {
    test('maps every dart_cast session state', () {
      expect(playbackStateFrom(dc.SessionState.playing), CastPlaybackState.playing);
      expect(playbackStateFrom(dc.SessionState.paused), CastPlaybackState.paused);
      expect(playbackStateFrom(dc.SessionState.buffering), CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.loading), CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.connecting), CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.idle), CastPlaybackState.idle);
      expect(playbackStateFrom(dc.SessionState.connected), CastPlaybackState.idle);
      expect(playbackStateFrom(dc.SessionState.disconnected), CastPlaybackState.idle);
    });
  });
}
