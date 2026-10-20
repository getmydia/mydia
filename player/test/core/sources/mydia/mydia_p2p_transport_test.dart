import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/domain/sources/source_error.dart';

class _ScriptedP2p extends P2pService {
  _ScriptedP2p(this.answer);
  final Future<Map<String, dynamic>> Function() answer;
  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) =>
      answer();
}

class _CountingP2p extends P2pService {
  _CountingP2p(this.answers);
  final List<Future<Map<String, dynamic>> Function()> answers;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) =>
      answers[calls++]();
}

Matcher _kind(SourceErrorKind kind) =>
    throwsA(isA<SourceException>().having((e) => e.kind, 'kind', kind));

Future<Map<String, dynamic>> _send(Future<Map<String, dynamic>> Function() a) =>
    P2pMydiaTransport(p2p: _ScriptedP2p(a), nodeAddr: 'node').send('{ a }', {});

void main() {
  test('a GraphQL error answer is a server error with its message', () async {
    await expectLater(
        _send(() async =>
            throw const P2pGraphQLError('Invalid or revoked device token')),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.server)
            .having((e) => e.message, 'message',
                'Invalid or revoked device token')));
  });

  test('the auth wording is unauthorized', () async {
    await expectLater(
        _send(() async => throw const P2pGraphQLError('Unauthorized')),
        _kind(SourceErrorKind.unauthorized));
  });

  test('a dial failure is unreachable', () async {
    await expectLater(_send(() async => throw StateError('dial failed')),
        _kind(SourceErrorKind.unreachable));
  });

  test('a timeout is unreachable', () async {
    await expectLater(_send(() async => throw TimeoutException('slow')),
        _kind(SourceErrorKind.unreachable));
  });

  test('P2pGraphQLError prints like the Exception it replaces', () {
    expect(const P2pGraphQLError('boom').toString(), 'Exception: boom');
  });

  test('passes device profile and auth token to P2pService', () async {
    final p2p = _RecordingP2p();
    final transport = P2pMydiaTransport(p2p: p2p, nodeAddr: 'node');
    await transport.send(
      '{ a }',
      {},
      token: 'tok-1',
      deviceProfile: 'prof-val',
    );
    expect(p2p.lastToken, 'tok-1');
    expect(p2p.lastDeviceProfile, 'prof-val');
  });

  group('retry after a transport failure', () {
    test('a query is retried once and returns the second answer', () async {
      final p2p = _CountingP2p([
        () async => throw Exception('connection_stalled: no answer'),
        () async => {'a': 1},
      ]);
      final result = await P2pMydiaTransport(p2p: p2p, nodeAddr: 'node')
          .send('query Q { a }', {});
      expect(result, {'a': 1});
      expect(p2p.calls, 2);
    });

    test('an anonymous query is retried too', () async {
      final p2p = _CountingP2p([
        () async => throw StateError('closed'),
        () async => {'a': 1},
      ]);
      await P2pMydiaTransport(p2p: p2p, nodeAddr: 'node').send('{ a }', {});
      expect(p2p.calls, 2);
    });

    test('a mutation is never retried', () async {
      final p2p = _CountingP2p([
        () async => throw Exception('connection_stalled: no answer'),
        () async => {'a': 1},
      ]);
      await expectLater(
          P2pMydiaTransport(p2p: p2p, nodeAddr: 'node')
              .send('mutation M { a }', {}),
          _kind(SourceErrorKind.unreachable));
      expect(p2p.calls, 1);
    });

    test('a server answer is never retried', () async {
      final p2p = _CountingP2p([
        () async => throw const P2pGraphQLError('boom'),
        () async => {'a': 1},
      ]);
      await expectLater(
          P2pMydiaTransport(p2p: p2p, nodeAddr: 'node').send('{ a }', {}),
          throwsA(isA<MydiaGraphqlError>()));
      expect(p2p.calls, 1);
    });

    test('a connect failure is not retried', () async {
      final p2p = _CountingP2p([
        () async => throw P2pConnectError(Exception('dial failed')),
        () async => {'a': 1},
      ]);
      await expectLater(
          P2pMydiaTransport(p2p: p2p, nodeAddr: 'node').send('{ a }', {}),
          _kind(SourceErrorKind.unreachable));
      expect(p2p.calls, 1);
    });

    test('a query failing twice is unreachable', () async {
      final p2p = _CountingP2p([
        () async => throw StateError('closed'),
        () async => throw StateError('closed again'),
      ]);
      await expectLater(
          P2pMydiaTransport(p2p: p2p, nodeAddr: 'node').send('{ a }', {}),
          _kind(SourceErrorKind.unreachable));
      expect(p2p.calls, 2);
    });

    test('an unparseable document is not retried', () async {
      final p2p = _CountingP2p([
        () async => throw StateError('closed'),
        () async => {'a': 1},
      ]);
      await expectLater(
          P2pMydiaTransport(p2p: p2p, nodeAddr: 'node').send('{{{', {}),
          _kind(SourceErrorKind.unreachable));
      expect(p2p.calls, 1);
    });
  });
}

class _RecordingP2p extends P2pService {
  String? lastToken;
  String? lastDeviceProfile;

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
    String? deviceProfile,
  }) async {
    lastToken = authToken;
    lastDeviceProfile = deviceProfile;
    return {'ok': true};
  }
}
