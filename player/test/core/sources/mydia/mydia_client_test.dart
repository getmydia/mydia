import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart' show parseString;
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/graphql/queries/mydia_queries.dart';

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
  late List<MydiaCredentials> saved;
  late int unauthorized;

  late int loads;

  MydiaClient build(
          {String? deviceToken = 'device', String token = 'access'}) =>
      MydiaClient(
        transport: transport,
        load: () async {
          loads++;
          return MydiaCredentials(
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
    await client.request(documentNodeQueryMydiaInstanceIdentity);
    await client.request(documentNodeQueryMydiaInstanceIdentity);
    expect(loads, 1);
  });

  test('sends the current access token and reports the server reached',
      () async {
    final client = build();
    final data = await client.request(documentNodeQueryMydiaInstanceIdentity);
    expect((data['serverCompatibility'] as Map)['instanceId'], 'inst-2');
    expect(transport.calls.single.token, 'access');
    expect(client.status.value, SourceConnectionStatus.remote);
  });

  test('a rejected token is refreshed with the device token, saved and retried',
      () async {
    transport.validTokens = {'fresh'};
    final client = build();
    await client.request(documentNodeQueryMydiaInstanceIdentity);
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
        client.request(documentNodeQueryMydiaInstanceIdentity),
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
        client.request(documentNodeQueryMydiaInstanceIdentity),
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
        client.request(documentNodeQueryMydiaInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)));
    expect(unauthorized, 0);
    expect(saved, isEmpty);
    expect(client.status.value, SourceConnectionStatus.unreachable);
  });

  test('a refresh the server rejects with an error flags the account',
      () async {
    transport.validTokens = {};
    transport.handlers['RefreshAccessToken'] = (_) =>
        throw const SourceException.server('Invalid or revoked device token');
    final client = build();
    await expectLater(
        client.request(documentNodeQueryMydiaInstanceIdentity),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)));
    expect(unauthorized, 1);
    expect(saved, isEmpty);
  });

  test('a retry rejected again flags the account', () async {
    transport.validTokens = {};
    final client = build();
    await expectLater(
        client.request(documentNodeQueryMydiaInstanceIdentity),
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
    final late = client.request(documentNodeQueryMydiaInstanceIdentity);
    await Future<void>.delayed(Duration.zero);
    await client.request(documentNodeQueryMydiaInstanceIdentity);
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
    await expectLater(client.request(documentNodeQueryMydiaInstanceIdentity),
        throwsA(isA<SourceException>()));
    expect(client.status.value, SourceConnectionStatus.unreachable);
  });

  test('concurrent rejections share one refresh', () async {
    transport.validTokens = {'fresh'};
    final client = build();
    await Future.wait([
      client.request(documentNodeQueryMydiaInstanceIdentity),
      client.request(documentNodeQueryMydiaInstanceIdentity),
    ]);
    expect(transport.calls.where((c) => c.operation == 'RefreshAccessToken'),
        hasLength(1));
  });

  test('coalesces concurrent 401s into a single refresh request', () async {
    transport.validTokens = {'fresh'};
    final refreshCompleter = Completer<Map<String, dynamic>>();
    transport.handlers['RefreshAccessToken'] = (_) => refreshCompleter.future;

    final client = build();
    final f1 = client.request(documentNodeQueryMydiaInstanceIdentity);
    final f2 = client.request(documentNodeQueryMydiaInstanceIdentity);
    final f3 = client.request(documentNodeQueryMydiaInstanceIdentity);

    // Yield to let all requests send and receive 401
    await Future<void>.delayed(Duration.zero);

    // Only one RefreshAccessToken mutation should have been dispatched
    expect(
      transport.calls.where((c) => c.operation == 'RefreshAccessToken'),
      hasLength(1),
    );

    refreshCompleter.complete({
      'refreshAccessToken': {'token': 'fresh', 'expiresAt': null},
    });

    final results = await Future.wait([f1, f2, f3]);
    for (final data in results) {
      expect((data['serverCompatibility'] as Map)['instanceId'], 'inst-2');
    }

    expect(
      transport.calls.where((c) => c.operation == 'RefreshAccessToken'),
      hasLength(1),
    );
    expect(saved.single.accessToken, 'fresh');
    expect((await client.credentials()).accessToken, 'fresh');
    expect(unauthorized, 0);
  });

  test('refused refresh invokes onUnauthorized', () async {
    transport.validTokens = {};
    transport.handlers['RefreshAccessToken'] =
        (_) => throw const SourceException.unauthorized();
    final client = build();

    await expectLater(
      client.request(documentNodeQueryMydiaInstanceIdentity),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
    );

    expect(unauthorized, 1);
    expect(saved, isEmpty);
    expect((await client.credentials()).accessToken, 'access');

    // Concurrent requests on refused refresh invoke onUnauthorized once for the refusal
    final client2 = build();
    await expectLater(
      Future.wait([
        client2.request(documentNodeQueryMydiaInstanceIdentity),
        client2.request(documentNodeQueryMydiaInstanceIdentity),
      ]),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
    );
    expect(unauthorized, 2);
  });

  test('unreachable during refresh does not invoke onUnauthorized', () async {
    transport.validTokens = {};
    transport.handlers['RefreshAccessToken'] =
        (_) => throw const SourceException.unreachable();
    final client = build();

    await expectLater(
      client.request(documentNodeQueryMydiaInstanceIdentity),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)),
    );

    expect(unauthorized, 0);
    expect(saved, isEmpty);
    expect(client.status.value, SourceConnectionStatus.unreachable);
    expect((await client.credentials()).accessToken, 'access');

    // Concurrent requests experiencing unreachable refresh also do not flag reauth
    final client2 = build();
    await expectLater(
      Future.wait([
        client2.request(documentNodeQueryMydiaInstanceIdentity),
        client2.request(documentNodeQueryMydiaInstanceIdentity),
      ]),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)),
    );
    expect(unauthorized, 0);
    expect(client2.status.value, SourceConnectionStatus.unreachable);
    expect((await client2.credentials()).accessToken, 'access');
  });

  test(
      'retries with fallback on unknown field error and skips straight to fallback on next call',
      () async {
    final extended = parseString('query GetItem { item { id newField } }');
    final fallback = parseString('query GetItemFallback { item { id } }');

    transport.handlers['GetItem'] = (_) => throw const SourceException.server(
          'Cannot query field "newField" on type "Item"',
        );
    transport.handlers['GetItemFallback'] = (_) => {
          'item': {'id': '1'},
        };

    final client = build();

    final firstResult = await client.query(extended, fallback: fallback);
    expect(firstResult, {
      'item': {'id': '1'}
    });
    expect(transport.calls.map((c) => c.operation), [
      'GetItem',
      'GetItemFallback',
    ]);

    final secondResult = await client.query(extended, fallback: fallback);
    expect(secondResult, {
      'item': {'id': '1'}
    });
    expect(transport.calls.map((c) => c.operation), [
      'GetItem',
      'GetItemFallback',
      'GetItemFallback',
    ]);
  });

  test('does not use fallback on ordinary server error', () async {
    final extended = parseString('query GetItem { item { id newField } }');
    final fallback = parseString('query GetItemFallback { item { id } }');

    transport.handlers['GetItem'] = (_) => throw const SourceException.server(
          'Internal server error',
        );

    final client = build();

    await expectLater(
      client.query(extended, fallback: fallback),
      throwsA(isA<SourceException>()),
    );
    expect(transport.calls.map((c) => c.operation), ['GetItem']);
  });

  test('surfaces unknown field error when no fallback is provided', () async {
    final extended = parseString('query GetItem { item { id newField } }');

    transport.handlers['GetItem'] = (_) => throw const SourceException.server(
          'Cannot query field "newField" on type "Item"',
        );

    final client = build();

    await expectLater(
      client.query(extended),
      throwsA(isA<SourceException>()),
    );
    expect(transport.calls.map((c) => c.operation), ['GetItem']);
  });
}
