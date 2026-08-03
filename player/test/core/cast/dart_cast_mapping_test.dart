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

/// A [dc.CastSession] that records the lifecycle calls made against it.
///
/// Deliberately inert: `dc.CastService.connect` disconnects its own previous
/// session, so a fake that did the same would mask whether *this* backend
/// hands the old receiver back. Nothing here happens unless the code under
/// test asks for it.
class _RecordingSession extends dc.CastSession {
  _RecordingSession(super.device);

  bool disconnected = false;
  bool disposed = false;

  @override
  Future<void> loadMedia(dc.CastMedia media) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitle(dc.CastSubtitle? subtitle) async {}

  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

class _RecordingCastService extends dc.CastService {
  final List<_RecordingSession> sessions = [];

  @override
  Future<dc.CastSession> connect(dc.CastDevice device) async {
    final session = _RecordingSession(device);
    sessions.add(session);
    return session;
  }
}

void main() {
  group('DartCastBackend.connect session handover', () {
    const receiverA = CastDevice(
      id: 'a',
      name: 'Living room',
      protocol: CastProtocolKind.chromecast,
      host: '192.168.1.50',
      port: 8009,
    );
    const receiverB = CastDevice(
      id: 'b',
      name: 'Bedroom',
      protocol: CastProtocolKind.chromecast,
      host: '192.168.1.51',
      port: 8009,
    );

    test('casting to a second receiver hands the first one back', () async {
      // Regression test: `_session` used to be overwritten on the second
      // connect. The first receiver was then left playing our media with
      // nothing able to stop it, and its stream controllers leaked.
      final service = _RecordingCastService();
      final backend = DartCastBackend.withService(service);
      addTearDown(backend.dispose);

      await backend.connect(receiverA);
      await backend.connect(receiverB);

      expect(service.sessions, hasLength(2));
      expect(service.sessions.first.disconnected, isTrue,
          reason: 'the first receiver must be released');
      expect(service.sessions.first.disposed, isTrue,
          reason: 'the first session must not leak its stream controllers');
      expect(service.sessions.last.disconnected, isFalse);
      expect(backend.connectedDevice?.id, 'b');
    });

    test('reconnecting to the same receiver does not tear its session down',
        () async {
      final service = _RecordingCastService();
      final backend = DartCastBackend.withService(service);
      addTearDown(backend.dispose);

      await backend.connect(receiverA);
      await backend.connect(receiverA);

      expect(service.sessions.first.disconnected, isFalse);
      expect(backend.connectedDevice?.id, 'a');
    });
  });

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
        metadata: const {
          'avTransportControlUrl': 'http://192.168.1.51:1900/AVTransport'
        },
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

    test(
        'rebuilds a DLNA device including the control-URL metadata '
        'DlnaSession.fromDevice needs', () {
      const domain = CastDevice(
        id: 'uuid:1',
        name: 'Bedroom TV',
        protocol: CastProtocolKind.dlna,
        host: '192.168.1.51',
        port: 1900,
        metadata: {
          'avTransportControlUrl':
              'http://192.168.1.51:1900/AVTransport/control',
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

  group('DartCastBackend.connect reconstruction failures', () {
    test(
        'a malformed persisted host surfaces as CastBackendException, not a '
        'raw ArgumentError', () async {
      // Regression test: reconstructDartCastDevice used to run outside the
      // try/catch that translates dart_cast errors. InternetAddress(host)
      // throws a synchronous ArgumentError for anything that isn't a valid
      // IP literal — before any actual networking happens, so this needs no
      // hardware to exercise.
      final backend = DartCastBackend();
      addTearDown(backend.dispose);

      const neverDiscovered = CastDevice(
        id: 'ghost',
        name: 'Ghost TV',
        protocol: CastProtocolKind.chromecast,
        host: 'not-a-valid-ip-address',
        port: 8009,
      );

      await expectLater(
        backend.connect(neverDiscovered),
        throwsA(isA<CastBackendException>()
            .having((e) => e.kind, 'kind', CastFailureKind.unknown)),
      );
    });
  });

  group('playbackStateFrom', () {
    test('maps every dart_cast session state', () {
      expect(playbackStateFrom(dc.SessionState.playing),
          CastPlaybackState.playing);
      expect(
          playbackStateFrom(dc.SessionState.paused), CastPlaybackState.paused);
      expect(playbackStateFrom(dc.SessionState.buffering),
          CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.loading),
          CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.connecting),
          CastPlaybackState.buffering);
      expect(playbackStateFrom(dc.SessionState.idle), CastPlaybackState.idle);
      expect(
          playbackStateFrom(dc.SessionState.connected), CastPlaybackState.idle);
      expect(playbackStateFrom(dc.SessionState.disconnected),
          CastPlaybackState.idle);
    });
  });

  group('failureKindFor', () {
    test(
        'maps DeviceUnreachableException to unreachable (future-proofing; '
        'never actually thrown today)', () {
      expect(
        failureKindFor(dc.DeviceUnreachableException('unreachable')),
        CastFailureKind.unreachable,
      );
    });

    test(
        'maps ProxyUpstreamException to unreachable (future-proofing; '
        'never actually thrown today)', () {
      expect(
        failureKindFor(dc.ProxyUpstreamException('proxy failed')),
        CastFailureKind.unreachable,
      );
    });

    test(
        'maps MediaLoadFailedException (the real Chromecast LOAD failure) '
        'to mediaLoadFailed', () {
      expect(
        failureKindFor(dc.MediaLoadFailedException('LOAD_FAILED')),
        CastFailureKind.mediaLoadFailed,
      );
    });

    test(
        'maps ProtocolException (the real DLNA SOAP failure) to '
        'mediaLoadFailed, the same as Chromecast\'s LOAD failure', () {
      expect(
        failureKindFor(dc.ProtocolException('HTTP 500', dc.CastProtocol.dlna)),
        CastFailureKind.mediaLoadFailed,
      );
    });

    test(
        'maps ConnectionLostException to connectionLost (future-proofing; '
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
      expect(
          failureKindFor(dc.CastException('mystery')), CastFailureKind.unknown);
    });
  });

  group('mapDiscoveryFailures', () {
    test('translates each discovery exception through failureKindFor',
        () async {
      final controller = StreamController<dc.CastException>();
      addTearDown(controller.close);

      final kinds = <CastFailureKind>[];
      mapDiscoveryFailures(controller.stream).listen(kinds.add);

      controller.add(dc.DiscoveryException('denied'));
      await Future<void>.delayed(Duration.zero);

      expect(kinds, [CastFailureKind.discoveryDenied]);
    });
  });

  group('sanitizeDurations', () {
    /// A Chromecast fed one of Mydia's live-style HLS playlists reports
    /// `duration: -1`, and `dart_cast` forwards it verbatim. Letting that
    /// through is what made the scrub bar read `00:-1` and both the slider
    /// and the skip-ahead button seek to the start of the video.
    test('drops the receiver\'s -1 unknown-duration placeholder', () async {
      final controller = StreamController<Duration>();
      addTearDown(controller.close);

      final durations = <Duration>[];
      sanitizeDurations(controller.stream).listen(durations.add);

      controller.add(const Duration(seconds: -1));
      await Future<void>.delayed(Duration.zero);

      expect(durations, isEmpty);
    });

    test('drops zero, which is equally not a runtime', () async {
      final controller = StreamController<Duration>();
      addTearDown(controller.close);

      final durations = <Duration>[];
      sanitizeDurations(controller.stream).listen(durations.add);

      controller.add(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(durations, isEmpty);
    });

    test('passes a real runtime through', () async {
      final controller = StreamController<Duration>();
      addTearDown(controller.close);

      final durations = <Duration>[];
      sanitizeDurations(controller.stream).listen(durations.add);

      controller.add(const Duration(minutes: 107));
      await Future<void>.delayed(Duration.zero);

      expect(durations, [const Duration(minutes: 107)]);
    });
  });

  group('isLocalNetworkAddress', () {
    test('accepts every private and link-local IPv4 range', () {
      for (final address in const [
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.1.42',
        '169.254.10.20',
      ]) {
        expect(isLocalNetworkAddress(InternetAddress(address)), isTrue,
            reason: '$address should be treated as local');
      }
    });

    test('rejects the 172.x addresses just outside the private block', () {
      // 172.16/12 is the narrowest range and the easiest to get wrong.
      expect(isLocalNetworkAddress(InternetAddress('172.15.0.1')), isFalse);
      expect(isLocalNetworkAddress(InternetAddress('172.32.0.1')), isFalse);
    });

    test('rejects public, loopback and carrier-grade NAT addresses', () {
      for (final address in const [
        '8.8.8.8',
        '1.1.1.1',
        '127.0.0.1',
        '100.64.0.1',
      ]) {
        expect(isLocalNetworkAddress(InternetAddress(address)), isFalse,
            reason: '$address should not be treated as local');
      }
    });

    test('accepts IPv6 link-local and unique-local addresses', () {
      expect(isLocalNetworkAddress(InternetAddress('fe80::1')), isTrue);
      expect(isLocalNetworkAddress(InternetAddress('fd00::1')), isTrue);
    });

    test('rejects IPv6 loopback and global unicast', () {
      expect(isLocalNetworkAddress(InternetAddress('::1')), isFalse);
      expect(isLocalNetworkAddress(InternetAddress('2001:4860:4860::8888')),
          isFalse);
    });
  });

  group('looksLikeLocalNetworkDenial', () {
    const denial = SocketException(
      'No route to host',
      osError: OSError('No route to host', 65),
    );

    test('matches EHOSTUNREACH to a local address on an Apple platform', () {
      expect(
        looksLikeLocalNetworkDenial(
          error: denial,
          target: InternetAddress('192.168.1.42'),
          applePlatform: true,
        ),
        isTrue,
      );
    });

    test('rejects the identical error off an Apple platform', () {
      // errno 65 is EHOSTUNREACH on Darwin but ENOPKG on Linux, where
      // EHOSTUNREACH is 113. Without the platform gate this would fire on
      // an unrelated error on every non-Apple target.
      expect(
        looksLikeLocalNetworkDenial(
          error: denial,
          target: InternetAddress('192.168.1.42'),
          applePlatform: false,
        ),
        isFalse,
      );
    });

    test('rejects other errnos', () {
      for (final code in const [51, 61, 113]) {
        expect(
          looksLikeLocalNetworkDenial(
            error: SocketException('nope', osError: OSError('nope', code)),
            target: InternetAddress('192.168.1.42'),
            applePlatform: true,
          ),
          isFalse,
          reason: 'errno $code is not EHOSTUNREACH on Darwin',
        );
      }
    });

    test('rejects a SocketException carrying no OSError', () {
      expect(
        looksLikeLocalNetworkDenial(
          error: const SocketException('bare'),
          target: InternetAddress('192.168.1.42'),
          applePlatform: true,
        ),
        isFalse,
      );
    });

    test('rejects errors that are not SocketExceptions', () {
      expect(
        looksLikeLocalNetworkDenial(
          error: ArgumentError('malformed host'),
          target: InternetAddress('192.168.1.42'),
          applePlatform: true,
        ),
        isFalse,
      );
    });

    test('rejects a public target', () {
      expect(
        looksLikeLocalNetworkDenial(
          error: denial,
          target: InternetAddress('93.184.216.34'),
          applePlatform: true,
        ),
        isFalse,
      );
    });

    test('rejects a null target', () {
      // reconstructDartCastDevice threw before any connection was attempted,
      // so there is nothing to blame the permission for.
      expect(
        looksLikeLocalNetworkDenial(
          error: denial,
          target: null,
          applePlatform: true,
        ),
        isFalse,
      );
    });
  });
}
