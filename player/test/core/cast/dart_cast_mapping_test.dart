import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/bonsoir_chromecast_discovery.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/dart_cast_backend.dart';
import 'package:player/domain/models/cast_device.dart';

/// No-op resolver for events that never actually need resolution in these
/// tests (only `BonsoirDiscoveryServiceFoundEvent` calls into it, and only
/// when `service.hostAddresses` is empty).
class _FakeServiceResolver with ServiceResolver {
  final List<BonsoirService> resolved = [];

  @override
  FutureOr<void> resolveService(BonsoirService service) {
    resolved.add(service);
  }

  @override
  FutureOr<bool> supportsMdnsHostname() => false;
}

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

  group('BonsoirChromecastDiscovery.applyBonsoirEvent', () {
    test('removes a lost device by id, not by its display name', () {
      final discovery = BonsoirChromecastDiscovery();
      final resolver = _FakeServiceResolver();

      // A real Chromecast's `fn` (friendly name) is what the picker shows,
      // but a lost event only ever carries the raw mDNS instance name —
      // never `fn`. Matching removal against `device.name` (the friendly
      // name) is exactly the bug this regresses.
      final resolvedService = const BonsoirService.ignoreNorms(
        name: 'Chromecast-abc123',
        type: chromecastServiceType,
        hostAddresses: ['192.168.1.50'],
        port: 8009,
        attributes: {'fn': 'Living Room', 'id': 'abc123'},
      );

      final afterResolve = discovery.applyBonsoirEvent(
        BonsoirDiscoveryServiceResolvedEvent(service: resolvedService),
        resolver,
      );
      expect(afterResolve, isNotNull);
      expect(afterResolve!.single.name, 'Living Room');

      final lostService = const BonsoirService.ignoreNorms(
        name: 'Chromecast-abc123',
        type: chromecastServiceType,
        port: 8009,
      );
      final afterLost = discovery.applyBonsoirEvent(
        BonsoirDiscoveryServiceLostEvent(service: lostService),
        resolver,
      );

      expect(afterLost, isNotNull);
      expect(afterLost, isEmpty);
    });

    test('a found event triggers resolution through the resolver', () {
      final discovery = BonsoirChromecastDiscovery();
      final resolver = _FakeServiceResolver();
      final service = const BonsoirService.ignoreNorms(
        name: 'Chromecast-abc123',
        type: chromecastServiceType,
        port: 8009,
      );

      final result = discovery.applyBonsoirEvent(
        BonsoirDiscoveryServiceFoundEvent(service: service),
        resolver,
      );

      expect(result, isNull);
      // `BonsoirService.resolve` only calls resolveService when
      // hostAddresses is empty, which is true for this unresolved service.
      expect(resolver.resolved, [service]);
    });

    test('an unresolvable service produces no snapshot', () {
      final discovery = BonsoirChromecastDiscovery();
      final resolver = _FakeServiceResolver();
      final service = const BonsoirService.ignoreNorms(
        name: 'Living Room',
        type: chromecastServiceType,
        port: 8009,
        // No hostAddresses — chromecastDeviceFromBonsoir returns null.
      );

      final result = discovery.applyBonsoirEvent(
        BonsoirDiscoveryServiceResolvedEvent(service: service),
        resolver,
      );

      expect(result, isNull);
    });
  });

  group('BonsoirChromecastDiscovery failure channel', () {
    test('surfaces a discovery failure that dart_cast would otherwise swallow',
        () async {
      final discovery = BonsoirChromecastDiscovery();
      addTearDown(discovery.dispose);

      final failures = <dc.CastException>[];
      discovery.failures.listen(failures.add);

      // No platform channel is registered in this test environment, so
      // `BonsoirDiscovery.initialize()` throws MissingPluginException — the
      // same "the platform refused" shape a real discovery denial takes.
      // dart_cast's own DiscoveryManager only logs a provider's stream
      // errors (see discovery_manager.dart) rather than forwarding them, so
      // `failures` is the only channel this can ever reach the app through.
      discovery.startDiscovery();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(failures, hasLength(1));
      expect(failures.single, isA<dc.DiscoveryException>());
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
      expect(domain.metadata['md'], 'Chromecast Ultra');
    });

    test('maps a DLNA device', () {
      final domain = toDomainDevice(dc.CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: dc.CastProtocol.dlna,
        address: InternetAddress('192.168.1.51'),
        port: 1900,
        metadata: const {'avTransportControlUrl': 'http://192.168.1.51:1900/AVTransport'},
      ));

      expect(domain.protocol, CastProtocolKind.dlna);
      expect(domain.model, isNull);
      expect(
        domain.metadata['avTransportControlUrl'],
        'http://192.168.1.51:1900/AVTransport',
      );
    });
  });

  group('reconstructDartCastDevice', () {
    test('rebuilds a Chromecast device from persisted host/port', () {
      const domain = CastDevice(
        id: 'abc',
        name: 'Living Room',
        protocol: CastProtocolKind.chromecast,
        host: '192.168.1.50',
        port: 8009,
        metadata: {'md': 'Chromecast Ultra'},
      );

      final rebuilt = reconstructDartCastDevice(domain);

      expect(rebuilt, isNotNull);
      expect(rebuilt!.id, 'abc');
      expect(rebuilt.protocol, dc.CastProtocol.chromecast);
      expect(rebuilt.address.address, '192.168.1.50');
      expect(rebuilt.port, 8009);
      expect(rebuilt.metadata['md'], 'Chromecast Ultra');
    });

    test('rebuilds a DLNA device including the control-URL metadata '
        'DlnaSession.fromDevice needs', () {
      const domain = CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
        host: '192.168.1.51',
        port: 1900,
        metadata: {
          'avTransportControlUrl': 'http://192.168.1.51:1900/AVTransport/control',
        },
      );

      final rebuilt = reconstructDartCastDevice(domain);

      expect(rebuilt, isNotNull);
      expect(rebuilt!.protocol, dc.CastProtocol.dlna);
      expect(
        rebuilt.metadata['avTransportControlUrl'],
        'http://192.168.1.51:1900/AVTransport/control',
      );
    });

    test('returns null when host is missing', () {
      const domain = CastDevice(
        id: 'abc',
        name: 'Living Room',
        protocol: CastProtocolKind.chromecast,
        port: 8009,
      );

      expect(reconstructDartCastDevice(domain), isNull);
    });

    test('returns null when port is missing', () {
      const domain = CastDevice(
        id: 'abc',
        name: 'Living Room',
        protocol: CastProtocolKind.chromecast,
        host: '192.168.1.50',
      );

      expect(reconstructDartCastDevice(domain), isNull);
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

  group('failureKindFor', () {
    test('maps DeviceUnreachableException to unreachable (future-proofing; '
        'never actually thrown today)', () {
      expect(
        failureKindFor(dc.DeviceUnreachableException('unreachable')),
        CastFailureKind.unreachable,
      );
    });

    test('maps ProxyUpstreamException to unreachable (future-proofing; '
        'never actually thrown today)', () {
      expect(
        failureKindFor(dc.ProxyUpstreamException('proxy failed')),
        CastFailureKind.unreachable,
      );
    });

    test('maps MediaLoadFailedException (the real Chromecast LOAD failure) '
        'to mediaLoadFailed', () {
      expect(
        failureKindFor(dc.MediaLoadFailedException('LOAD_FAILED')),
        CastFailureKind.mediaLoadFailed,
      );
    });

    test('maps ProtocolException (the real DLNA SOAP failure) to '
        'mediaLoadFailed, the same as Chromecast\'s LOAD failure', () {
      expect(
        failureKindFor(dc.ProtocolException('HTTP 500', dc.CastProtocol.dlna)),
        CastFailureKind.mediaLoadFailed,
      );
    });

    test('maps ConnectionLostException to connectionLost (future-proofing; '
        'never actually thrown today)', () {
      expect(
        failureKindFor(dc.ConnectionLostException('lost')),
        CastFailureKind.connectionLost,
      );
    });

    test('maps DiscoveryException to discoveryDenied', () {
      expect(
        failureKindFor(dc.DiscoveryException('denied')),
        CastFailureKind.discoveryDenied,
      );
    });

    test('maps an unrecognized CastException to unknown', () {
      expect(failureKindFor(dc.CastException('mystery')), CastFailureKind.unknown);
    });
  });

  group('mapDiscoveryFailures', () {
    test('translates each discovery exception through failureKindFor', () async {
      final controller = StreamController<dc.CastException>();
      addTearDown(controller.close);

      final kinds = <CastFailureKind>[];
      mapDiscoveryFailures(controller.stream).listen(kinds.add);

      controller.add(dc.DiscoveryException('denied'));
      await Future<void>.delayed(Duration.zero);

      expect(kinds, [CastFailureKind.discoveryDenied]);
    });
  });
}
