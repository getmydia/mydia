import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/mydia/mydia_guest_secrets.dart';
import 'package:player/core/sources/mydia/mydia_guest_source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'mydia_guest_wiring_test.dart' show guest;

class _CountingStorage extends MockAuthStorage {
  int reads = 0;

  /// The read with this number (1-based) throws.
  int? failRead;
  @override
  Future<String?> read(String key) async {
    reads++;
    if (reads == failRead) throw StateError('keychain locked');
    // Yield so concurrent callers overlap.
    await Future<void>.delayed(Duration.zero);
    return super.read(key);
  }
}

class _RecordingP2p extends P2pService {
  final peers = <String>[];
  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) async {
    peers.add(peer);
    return {'ok': 1};
  }
}

final _ping = parseString('query Ping { ok }');

final _sourceProvider =
    Provider<MydiaGuestSource>((ref) => buildGuestMydiaSource(ref, guest));

ProviderContainer _container(
  _CountingStorage storage, {
  P2pService? p2p,
  http.Client? client,
}) {
  final c = ProviderContainer(overrides: [
    sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
    if (p2p != null) p2pServiceProvider.overrideWithValue(p2p),
    sourceHttpProvider.overrideWithValue(SourceHttp(client: client)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a p2p credential sends through the p2p service to its node', () async {
    final storage = _CountingStorage();
    final p2p = _RecordingP2p();
    final secrets = SourceSecrets(storage);
    await writeGuestCredentials(
        secrets,
        guest.account,
        const MydiaGuestCredentials(
            instanceId: 'inst-2', accessToken: 'at', nodeAddr: '{"id":"n1"}'));
    final c = _container(storage, p2p: p2p);
    expect(await c.read(_sourceProvider).client.request(_ping), {'ok': 1});
    expect(p2p.peers, ['{"id":"n1"}']);
  });

  test('an HTTP credential posts to the server graphql endpoint', () async {
    final storage = _CountingStorage();
    final seen = <http.Request>[];
    final client = MockClient((r) async {
      seen.add(r);
      return http.Response(
          jsonEncode({
            'data': {'ok': 1}
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    await writeGuestCredentials(
        SourceSecrets(storage),
        guest.account,
        const MydiaGuestCredentials(
            instanceId: 'inst-2',
            accessToken: 'at',
            serverUrl: 'https://lakeside.example.test'));
    final c = _container(storage, client: client);
    expect(await c.read(_sourceProvider).client.request(_ping), {'ok': 1});
    expect(seen.single.url.toString(),
        'https://lakeside.example.test/api/graphql');
    expect(seen.single.headers['Authorization'], 'Bearer at');
  });

  test('a failed credentials read is not cached', () async {
    final storage = _CountingStorage();
    final p2p = _RecordingP2p();
    await writeGuestCredentials(
        SourceSecrets(storage),
        guest.account,
        const MydiaGuestCredentials(
            instanceId: 'inst-2', accessToken: 'at', nodeAddr: '{"id":"n1"}'));
    storage.reads = 0;
    // Read 1 is the client's, read 2 is the transport's.
    storage.failRead = 2;
    final client = _container(storage, p2p: p2p).read(_sourceProvider).client;
    await expectLater(client.request(_ping), throwsA(isA<StateError>()));
    expect(await client.request(_ping), {'ok': 1});
    expect(p2p.peers, ['{"id":"n1"}']);
  });

  test('missing credentials surface as unauthorized', () async {
    final source = _container(_CountingStorage()).read(_sourceProvider);
    await expectLater(
      source.client.request(_ping),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
    );
  });

  test('concurrent first requests build one transport', () async {
    final storage = _CountingStorage();
    final p2p = _RecordingP2p();
    await writeGuestCredentials(
        SourceSecrets(storage),
        guest.account,
        const MydiaGuestCredentials(
            instanceId: 'inst-2', accessToken: 'at', nodeAddr: '{"id":"n1"}'));
    storage.reads = 0;
    final c = _container(storage, p2p: p2p);
    final client = c.read(_sourceProvider).client;
    await Future.wait([client.request(_ping), client.request(_ping)]);
    // One read for the client's credentials and one for the transport.
    expect(storage.reads, 2);
  });
}
