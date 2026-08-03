import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart'
    show Operation, Request, gql;
import 'package:player/core/graphql/p2p_link.dart';
import 'package:player/core/p2p/p2p_service.dart';

/// Token value this fake treats as expired.
const _expiredToken = 'expired';

/// Records every send and rejects any request carrying [_expiredToken].
///
/// Mirrors how the server behaves once an access token ages past its Guardian
/// TTL: the transport surfaces the GraphQL error as a plain Exception.
class _FakeP2pService extends P2pService {
  final List<String?> tokensSeen = [];

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
  }) async {
    tokensSeen.add(authToken);

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
}
