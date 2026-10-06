import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:player/core/graphql/transport_link.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/graphql/mutations/refresh_media_token.graphql.dart';
import 'package:player/graphql/queries/server_compatibility.graphql.dart';

import '../sources/mydia/fake_mydia_transport.dart';

Map<String, dynamic> _compat(String version) => {
      '__typename': 'RootQueryType',
      'serverCompatibility': {
        '__typename': 'ServerCompatibility',
        'version': version,
        'minPlayerVersion': '1.0.0',
        'recommendedPlayerVersion': '1.0.0',
      },
    };

void main() {
  late FakeMydiaTransport transport;

  MydiaClient clientWith({String token = 'access'}) => MydiaClient(
        transport: transport,
        load: () async => MydiaCredentials(
          instanceId: 'inst-1',
          accessToken: token,
          deviceToken: 'device',
        ),
        save: (_) async {},
        onUnauthorized: () {},
      );

  GraphQLClient gqlOver(MydiaClient? client) => GraphQLClient(
        link: TransportLink(() async => client),
        cache: GraphQLCache(store: InMemoryStore()),
      );

  QueryOptions compatQuery() => QueryOptions(
        document: documentNodeQueryServerCompatibility,
        fetchPolicy: FetchPolicy.networkOnly,
      );

  setUp(() {
    transport = FakeMydiaTransport();
    transport.handlers['RefreshAccessToken'] = (_) => {
          'refreshAccessToken': {'token': 'fresh', 'expiresAt': null},
        };
  });

  test('query data comes back', () async {
    transport.handlers['ServerCompatibility'] = (_) => _compat('1.2.3');
    final r = await gqlOver(clientWith()).query(compatQuery());
    expect(r.hasException, isFalse);
    expect((r.data!['serverCompatibility'] as Map)['version'], '1.2.3');
  });

  test('a 401 refreshes once and retries', () async {
    transport.validTokens = {'fresh'};
    transport.handlers['ServerCompatibility'] = (_) => _compat('1.2.3');
    final r = await gqlOver(clientWith(token: 'stale')).query(compatQuery());
    expect(r.hasException, isFalse);
    expect(transport.calls.map((c) => c.operation), [
      'ServerCompatibility',
      'RefreshAccessToken',
      'ServerCompatibility',
    ]);
    expect(transport.calls.last.token, 'fresh');
  });

  test('unreachable becomes a linkException', () async {
    transport.unreachable = true;
    final r = await gqlOver(clientWith()).query(compatQuery());
    expect(r.exception?.linkException, isNotNull);
  });

  test('server error becomes a graphqlError with the message', () async {
    transport.handlers['ServerCompatibility'] = (_) =>
        throw const SourceException.server('Cannot query field "online"');
    final r = await gqlOver(clientWith()).query(compatQuery());
    expect(r.hasException, isTrue);
    expect(r.exception!.graphqlErrors, isNotEmpty);
    expect(r.exception.toString(), contains('Cannot query field "online"'));
  });

  test('mutations go through the same path', () async {
    transport.handlers['RefreshMediaToken'] = (_) => {
          '__typename': 'RootMutationType',
          'refreshMediaToken': {
            '__typename': 'MediaTokenResult',
            'token': 'm2',
            'expiresAt': null,
          },
        };
    final r = await gqlOver(clientWith()).mutate(MutationOptions(
      document: documentNodeMutationRefreshMediaToken,
      variables: const {'token': 'm1'},
      fetchPolicy: FetchPolicy.noCache,
    ));
    expect(transport.calls.single.operation, 'RefreshMediaToken');
    expect(transport.calls.single.vars, {'token': 'm1'});
    expect(r.data?['refreshMediaToken'], isNotNull);
  });

  test('no bound client: linkException', () async {
    final r = await gqlOver(null).query(compatQuery());
    expect(r.exception?.linkException, isNotNull);
  });
}
