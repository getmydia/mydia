import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart'
    show Operation, Request, gql;
import 'package:player/core/graphql/p2p_link.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/player/device_profile.dart';

/// Token value this fake treats as expired.
const _expiredToken = 'expired';

/// Records every send and rejects any request carrying [_expiredToken].
///
/// Mirrors how the server behaves once an access token ages past its Guardian
/// TTL: the transport surfaces the GraphQL error as a plain Exception.
class _FakeP2pService extends P2pService {
  final List<String?> tokensSeen = [];
  final List<String?> deviceProfilesSeen = [];

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) async {
    tokensSeen.add(authToken);
    deviceProfilesSeen.add(deviceProfile);

    if (authToken == _expiredToken) {
      throw Exception('Authentication required');
    }

    return {'movies': <String, dynamic>{}};
  }
}

Request _request() => Request(
      operation: Operation(
        document: gql('query Movies { movies { id } }'),
        operationName: 'Movies',
      ),
    );

void main() {
  group('P2pGraphQLLink access token recovery', () {
    test('refreshes and retries when the server rejects the token', () async {
      final service = _FakeP2pService();
      var refreshCalls = 0;

      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'expired',
        refreshAuthToken: () async {
          refreshCalls++;
          return 'fresh';
        },
      );

      final response = await link.request(_request()).first;

      expect(refreshCalls, 1, reason: 'should refresh exactly once');
      expect(service.tokensSeen, ['expired', 'fresh'],
          reason: 'retry must carry the refreshed token');
      expect(response.errors, isNull);
      expect(response.data, isNotNull);
    });

    test('does not refresh when the first attempt succeeds', () async {
      final service = _FakeP2pService();
      var refreshCalls = 0;

      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
        refreshAuthToken: () async {
          refreshCalls++;
          return 'fresh';
        },
      );

      final response = await link.request(_request()).first;

      expect(refreshCalls, 0);
      expect(service.tokensSeen, ['valid']);
      expect(response.errors, isNull);
    });

    test('surfaces the auth error when refresh cannot mint a token', () async {
      final service = _FakeP2pService();

      // Null models an unpaired client, or one whose device token was revoked:
      // there is nothing left to do but ask the user to pair again.
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'expired',
        refreshAuthToken: () async => null,
      );

      final response = await link.request(_request()).first;

      expect(service.tokensSeen, ['expired'], reason: 'must not retry blindly');
      expect(response.errors, isNotNull);
      expect(
          response.errors!.first.message, contains('Authentication required'));
    });

    test('surfaces the auth error when no refresher is wired', () async {
      final service = _FakeP2pService();

      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'expired',
      );

      final response = await link.request(_request()).first;

      expect(service.tokensSeen, ['expired']);
      expect(response.errors, isNotNull);
    });
  });

  group('P2pGraphQLLink device profile threading', () {
    // DeviceProfileHolder.instance is a process-wide singleton, the same one
    // graphql_provider.dart's deviceProfileHolderProvider hands to the HTTP
    // link. Reset it so a value set here cannot leak into another test.
    tearDown(() {
      DeviceProfileHolder.instance.profile = null;
    });

    test('carries null before the probe resolves', () async {
      final service = _FakeP2pService();
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
      );

      await link.request(_request()).first;

      expect(service.deviceProfilesSeen, [null]);
    });

    test('carries the encoded header value once the probe resolves', () async {
      const profile = DeviceProfile.webDefault();
      DeviceProfileHolder.instance.profile = profile;

      final service = _FakeP2pService();
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
      );

      await link.request(_request()).first;

      expect(service.deviceProfilesSeen, [profile.toHeaderValue()]);
    });
  });
}
