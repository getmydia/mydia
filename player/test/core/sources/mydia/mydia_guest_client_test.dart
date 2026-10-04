import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_guest_client.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/graphql/queries/guest_mydia.graphql.dart';

import 'fake_mydia_transport.dart';

/// Holds the first answer until [gate] completes.
class _GatedTransport extends FakeMydiaTransport {
  final gate = Completer<void>();
  bool _first = true;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
  }) async {
    if (_first) {
      _first = false;
      await gate.future;
    }
    return super.send(query, variables, token: token);
  }
}

void main() {
  late FakeMydiaTransport transport;
  late List<MydiaGuestCredentials> saved;
  late int unauthorized;

  late int loads;

  MydiaGuestClient build(
          {String? deviceToken = 'device', String token = 'access'}) =>
      MydiaGuestClient(
        transport: transport,
        load: () async {
          loads++;
          return MydiaGuestCredentials(
              instanceId: 'inst-2',
              accessToken: token,
              deviceToken: deviceToken);
        },
        save: (c) async => saved.add(c),
        onUnauthorized: () => unauthorized++,
      );

  setUp(() {
    transport = FakeMydiaTransport();
    transport.handlers['GuestInstanceIdentity'] = (_) => {
          'serverCompatibility': {'instanceId': 'inst-2'},
        };
    transport.handlers['RefreshAccessToken'] = (_) => {
          'refreshAccessToken': {'token': 'fresh', 'expiresAt': null},
        };
    saved = [];
    unauthorized = 0;
    loads = 0;
  });

  test('loads the credentials once, on first use', () async {
    final client = build();
    expect(loads, 0);
    await client.request(documentNodeQueryGuestInstanceIdentity);
    await client.request(documentNodeQueryGuestInstanceIdentity);
    expect(loads, 1);
  });

  test('sends the current access token and reports the server reached',
      () async {
    final client = build();
    final data = await client.request(documentNodeQueryGuestInstanceIdentity);
    expect((data['serverCompatibility'] as Map)['instanceId'], 'inst-2');
    expect(transport.calls.single.token, 'access');
    expect(client.status.value, SourceConnectionStatus.remote);
  });

  test('a rejected token is refreshed with the device token, saved and retried',
      () async {
    transport.validTokens = {'fresh'};
    final client = build();
    await client.request(documentNodeQueryGuestInstanceIdentity);
    expect(transport.calls.map((c) => c.operation), [
      'GuestInstanceIdentity',
      'RefreshAccessToken',
      'GuestInstanceIdentity',
    ]);
    expect(transport.calls[1].vars, {'deviceToken': 'device'});
    expect(transport.calls[1].token, isNull);
    expect(transport.calls.last.token, 'fresh');
    expect(saved.single.accessToken, 'fresh');
    expect((await client.credentials()).accessToken, 'fresh');
    expect(unauthorized, 0);
  });

  test('with no device token a rejection flags the account and throws',
      () async {
    transport.validTokens = {};
    final client = build(deviceToken: null);
    await expectLater(
        client.request(documentNodeQueryGuestInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)));
    expect(unauthorized, 1);
    expect(saved, isEmpty);
  });

  test('a refresh the server refuses flags the account once', () async {
    transport.validTokens = {};
    transport.handlers['RefreshAccessToken'] =
        (_) => throw const SourceException.unauthorized();
    final client = build();
    await expectLater(
        client.request(documentNodeQueryGuestInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)));
    expect(unauthorized, 1);
    expect(saved, isEmpty);
  });

  test('a refresh that fails transiently does not flag the account', () async {
    transport.validTokens = {};
    transport.handlers['RefreshAccessToken'] =
        (_) => throw const SourceException.unreachable();
    final client = build();
    await expectLater(
        client.request(documentNodeQueryGuestInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)));
    expect(unauthorized, 0);
    expect(saved, isEmpty);
    expect(client.status.value, SourceConnectionStatus.unreachable);
  });

  test('a retry rejected again flags the account', () async {
    transport.validTokens = {};
    final client = build();
    await expectLater(
        client.request(documentNodeQueryGuestInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)));
    expect(unauthorized, 1);
  });

  test('a late rejection of the old token retries without a second refresh',
      () async {
    transport.validTokens = {'fresh'};
    final gated = _GatedTransport()
      ..validTokens = transport.validTokens
      ..handlers.addAll(transport.handlers);
    transport = gated;
    final client = build();
    final late = client.request(documentNodeQueryGuestInstanceIdentity);
    await Future<void>.delayed(Duration.zero);
    await client.request(documentNodeQueryGuestInstanceIdentity);
    gated.gate.complete();
    await late;
    expect(transport.calls.where((c) => c.operation == 'RefreshAccessToken'),
        hasLength(1));
    expect(transport.calls.last.token, 'fresh');
    expect(unauthorized, 0);
  });

  test('an unreachable server sets the status and rethrows', () async {
    transport.unreachable = true;
    final client = build();
    await expectLater(client.request(documentNodeQueryGuestInstanceIdentity),
        throwsA(isA<SourceException>()));
    expect(client.status.value, SourceConnectionStatus.unreachable);
  });

  test('concurrent rejections share one refresh', () async {
    transport.validTokens = {'fresh'};
    final client = build();
    await Future.wait([
      client.request(documentNodeQueryGuestInstanceIdentity),
      client.request(documentNodeQueryGuestInstanceIdentity),
    ]);
    expect(transport.calls.where((c) => c.operation == 'RefreshAccessToken'),
        hasLength(1));
  });
}
