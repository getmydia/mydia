import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';

void main() {
  group('P2pConnectionType', () {
    test('has all expected values', () {
      expect(P2pConnectionType.values.length, equals(4));
      expect(P2pConnectionType.values, contains(P2pConnectionType.direct));
      expect(P2pConnectionType.values, contains(P2pConnectionType.relay));
      expect(P2pConnectionType.values, contains(P2pConnectionType.mixed));
      expect(P2pConnectionType.values, contains(P2pConnectionType.none));
    });

    test('direct has correct name', () {
      expect(P2pConnectionType.direct.name, equals('direct'));
    });

    test('relay has correct name', () {
      expect(P2pConnectionType.relay.name, equals('relay'));
    });

    test('mixed has correct name', () {
      expect(P2pConnectionType.mixed.name, equals('mixed'));
    });

    test('none has correct name', () {
      expect(P2pConnectionType.none.name, equals('none'));
    });
  });

  group('P2pStatus', () {
    group('initial factory', () {
      test('creates status with default values', () {
        const status = P2pStatus.initial();

        expect(status.isInitialized, isFalse);
        expect(status.isRelayConnected, isFalse);
        expect(status.connectedPeersCount, equals(0));
        expect(status.nodeAddr, isNull);
        expect(status.relayUrl, isNull);
        expect(status.peerConnectionType, equals(P2pConnectionType.none));
      });
    });

    group('constructor', () {
      test('creates status with required fields', () {
        const status = P2pStatus(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 5,
        );

        expect(status.isInitialized, isTrue);
        expect(status.isRelayConnected, isTrue);
        expect(status.connectedPeersCount, equals(5));
      });

      test('creates status with all fields', () {
        const status = P2pStatus(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 3,
          nodeAddr: '{"id":"abc123","addrs":[]}',
          relayUrl: 'https://relay.example.com',
          peerConnectionType: P2pConnectionType.direct,
        );

        expect(status.isInitialized, isTrue);
        expect(status.isRelayConnected, isTrue);
        expect(status.connectedPeersCount, equals(3));
        expect(status.nodeAddr, equals('{"id":"abc123","addrs":[]}'));
        expect(status.relayUrl, equals('https://relay.example.com'));
        expect(status.peerConnectionType, equals(P2pConnectionType.direct));
      });

      test('defaults peerConnectionType to none', () {
        const status = P2pStatus(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 0,
        );

        expect(status.peerConnectionType, equals(P2pConnectionType.none));
      });
    });

    group('copyWith', () {
      test('preserves all fields when no arguments provided', () {
        const original = P2pStatus(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 5,
          nodeAddr: '{"id":"test"}',
          relayUrl: 'https://relay.example.com',
          peerConnectionType: P2pConnectionType.mixed,
        );

        final copy = original.copyWith();

        expect(copy.isInitialized, equals(original.isInitialized));
        expect(copy.isRelayConnected, equals(original.isRelayConnected));
        expect(copy.connectedPeersCount, equals(original.connectedPeersCount));
        expect(copy.nodeAddr, equals(original.nodeAddr));
        expect(copy.relayUrl, equals(original.relayUrl));
        expect(copy.peerConnectionType, equals(original.peerConnectionType));
      });

      test('updates isInitialized', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(isInitialized: true);

        expect(updated.isInitialized, isTrue);
        expect(updated.isRelayConnected, equals(original.isRelayConnected));
      });

      test('updates isRelayConnected', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(isRelayConnected: true);

        expect(updated.isRelayConnected, isTrue);
        expect(updated.isInitialized, equals(original.isInitialized));
      });

      test('updates connectedPeersCount', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(connectedPeersCount: 10);

        expect(updated.connectedPeersCount, equals(10));
      });

      test('updates nodeAddr', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(nodeAddr: '{"id":"new-addr"}');

        expect(updated.nodeAddr, equals('{"id":"new-addr"}'));
      });

      test('updates relayUrl', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(relayUrl: 'https://new-relay.com');

        expect(updated.relayUrl, equals('https://new-relay.com'));
      });

      test('updates peerConnectionType', () {
        const original = P2pStatus.initial();
        final updated =
            original.copyWith(peerConnectionType: P2pConnectionType.direct);

        expect(updated.peerConnectionType, equals(P2pConnectionType.direct));
      });

      test('updates multiple fields at once', () {
        const original = P2pStatus.initial();
        final updated = original.copyWith(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 3,
          peerConnectionType: P2pConnectionType.relay,
        );

        expect(updated.isInitialized, isTrue);
        expect(updated.isRelayConnected, isTrue);
        expect(updated.connectedPeersCount, equals(3));
        expect(updated.peerConnectionType, equals(P2pConnectionType.relay));
        expect(updated.nodeAddr, isNull);
        expect(updated.relayUrl, isNull);
      });
    });

    group('default relay URL constant', () {
      test('has expected value', () {
        expect(defaultRelayUrl, equals('https://cae1-1.relay.mydia.dev'));
      });
    });

    group('nodeId', () {
      test('is null before the host is initialized', () {
        expect(const P2pStatus.initial().nodeId, isNull);
      });

      test('is carried through copyWith', () {
        final status = P2pStatus(
          isInitialized: true,
          isRelayConnected: true,
          connectedPeersCount: 0,
          nodeId: 'a' * 64,
        );

        expect(status.copyWith().nodeId, 'a' * 64);
        expect(status.copyWith(nodeId: 'b' * 64).nodeId, 'b' * 64);
      });
    });
  });
}
