import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/relay/claim_resolve_result.dart';
import 'package:player/core/relay/relay_api_client.dart';

import '../../test_utils/mock_auth_storage.dart';

const _nodeAddr = '{"id":"node-abc","addrs":[]}';

/// Answers pairing without a native host.
class _PairingP2p extends P2pService {
  @override
  Future<void> initialize({List<String>? relayUrls}) async {}

  @override
  Future<void> dial(String endpointAddrJson) async {}

  @override
  Future<Map<String, dynamic>> sendPairingRequest({
    required String peer,
    required String claimCode,
    required String deviceName,
    required String deviceType,
  }) async =>
      {
        'mediaToken': 'media-tok',
        'accessToken': 'access-tok',
        'deviceToken': 'device-tok',
      };
}

class _Relay extends RelayApiClient {
  _Relay(this.result);
  final ClaimResolveResult result;

  @override
  Future<ClaimResolveResult> resolveClaimCode(String code) async => result;
}

void main() {
  late MockAuthStorage storage;
  late _PairingP2p p2p;

  setUp(() {
    storage = MockAuthStorage();
    p2p = _PairingP2p();
  });

  tearDown(() => p2p.dispose());

  group('pairing writes nothing itself', () {
    test('claim code', () async {
      final service = PairingService(
        authStorage: storage,
        p2pService: p2p,
        relayClient: _Relay(
            ClaimResolveResult(nodeAddr: _nodeAddr, instanceId: 'inst-1')),
      );

      final result = await service.pairWithClaimCodeOnly(
          claimCode: 'ABC123', deviceName: 'Test', platform: 'linux');

      expect(result.success, isTrue);
      expect(result.credentials!.instanceId, 'inst-1');
      expect(result.credentials!.serverNodeAddr, _nodeAddr);
      expect(storage.keys, isEmpty);
    });

    test('claim code from a v1 relay has no instance id', () async {
      final service = PairingService(
        authStorage: storage,
        p2pService: p2p,
        relayClient: _Relay(ClaimResolveResult(nodeAddr: _nodeAddr)),
      );

      final result = await service.pairWithClaimCodeOnly(
          claimCode: 'ABC123', deviceName: 'Test', platform: 'linux');

      expect(result.credentials!.instanceId, isNull);
    });

    test('QR', () async {
      final service = PairingService(authStorage: storage, p2pService: p2p);

      final result = await service.pairWithQrData(
        qrData: const QrPairingData(
            nodeAddr: _nodeAddr, claimCode: 'ABC123', instanceId: 'inst-2'),
        deviceName: 'Test',
        platform: 'linux',
      );

      expect(result.success, isTrue);
      expect(result.credentials!.instanceId, 'inst-2');
      expect(storage.keys, isEmpty);
    });
  });
}
