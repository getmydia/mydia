import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart'
    show
        FetchPolicy,
        GraphQLCache,
        InMemoryStore,
        Operation,
        QueryOptions,
        Request,
        gql;
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
  final List<String?> operationNamesSeen = [];

  @override
  Future<void> ensureConnected(String endpointAddrJson) async {}

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) async {
    operationNamesSeen.add(operationName);
    tokensSeen.add(authToken);
    deviceProfilesSeen.add(deviceProfile);

    if (authToken == _expiredToken) {
      throw Exception('Authentication required');
    }

    return {'movies': <String, dynamic>{}};
  }
}

class _RetryP2pService extends P2pService {
  int attempts = 0;
  final int succeedOnAttempt;
  final Object failureError;

  _RetryP2pService({
    required this.succeedOnAttempt,
    required this.failureError,
  });

  @override
  Future<void> ensureConnected(String endpointAddrJson) async {}

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) async {
    final currentAttempt = attempts++;
    if (currentAttempt < succeedOnAttempt) {
      if (failureError is Exception) {
        throw failureError;
      } else if (failureError is Error) {
        throw failureError;
      }
      throw Exception(failureError.toString());
    }
    return {
      '__typename': 'Query',
      'movies': <String, dynamic>{
        '__typename': 'Movies',
        'id': '1',
      },
    };
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

  group('P2pGraphQLLink retry and timeout configuration', () {
    test('createP2pGraphQLClient configures queryRequestTimeout to null', () {
      final service = _FakeP2pService();
      final client = createP2pGraphQLClient(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
        cache: GraphQLCache(store: InMemoryStore()),
      );

      expect(client.queryManager.requestTimeout, isNull);
    });

    test(
        'retries on TimeoutException and resolves without Future already completed error',
        () async {
      final service = _RetryP2pService(
        succeedOnAttempt: 1,
        failureError: TimeoutException('P2P connection timed out'),
      );

      final client = createP2pGraphQLClient(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
        baseBackoff: const Duration(milliseconds: 10),
        cache: GraphQLCache(store: InMemoryStore()),
      );

      final result = await client.query(
        QueryOptions(
          document: gql('query Movies { movies { id } }'),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      expect(result.hasException, isFalse);
      expect(result.data?['movies']?['id'], '1');
      expect(service.attempts, 2);
    });

    test(
        'exhausts retries and returns exception without Future already completed error',
        () async {
      final service = _RetryP2pService(
        succeedOnAttempt: 99,
        failureError: TimeoutException('P2P connection timed out'),
      );

      final client = createP2pGraphQLClient(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
        baseBackoff: const Duration(milliseconds: 10),
        cache: GraphQLCache(store: InMemoryStore()),
      );

      final result = await client.query(
        QueryOptions(
          document: gql('query Movies { movies { id } }'),
          fetchPolicy: FetchPolicy.networkOnly,
        ),
      );

      expect(result.hasException, isTrue);
      expect(
        result.exception.toString(),
        contains('P2P connection timed out'),
      );
      expect(service.attempts, 4);
    });
  });

  group('P2pGraphQLLink operation names', () {
    test('names an unnamed request after the operation in its document',
        () async {
      // Generated documents leave Operation.operationName null, so every
      // request logged and travelled as "null".
      final service = _FakeP2pService();
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
      );

      await link
          .request(Request(
            operation: Operation(
              document: gql('query SeasonEpisodes { seasonEpisodes { id } }'),
            ),
          ))
          .first;

      expect(service.operationNamesSeen, ['SeasonEpisodes']);
    });

    test('keeps an explicit operation name', () async {
      final service = _FakeP2pService();
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
      );

      await link.request(_request()).first;

      expect(service.operationNamesSeen, ['Movies']);
    });

    test('sends null for an anonymous operation', () async {
      final service = _FakeP2pService();
      final link = P2pGraphQLLink(
        p2pService: service,
        serverNodeId: 'node',
        getAuthToken: () async => 'valid',
      );

      await link
          .request(Request(
            operation: Operation(document: gql('{ movies { id } }')),
          ))
          .first;

      expect(service.operationNamesSeen, [null]);
    });
  });
}
