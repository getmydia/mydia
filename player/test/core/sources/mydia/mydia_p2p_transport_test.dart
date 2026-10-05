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
