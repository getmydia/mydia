import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gql/language.dart' show parseString;
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/player/device_profile.dart';
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
    String? deviceProfile,
  }) async {
    if (_first) {
      _first = false;
      await gate.future;
    }
    return super
        .send(query, variables, token: token, deviceProfile: deviceProfile);
  }
}

void main() {
  late FakeMydiaTransport transport;
  late List<MydiaCredentials> saved;
  late int unauthorized;

  late int loads;

  MydiaClient build({
    String? deviceToken = 'device',
    String token = 'access',
    String? mediaToken,
    DateTime? mediaTokenExpiry,
    GetDeviceProfile? getDeviceProfile,
  }) =>
      MydiaClient(
        transport: transport,
        load: () async {
          loads++;
          return MydiaCredentials(
            instanceId: 'inst-2',
            accessToken: token,
            deviceToken: deviceToken,
            mediaToken: mediaToken,
            mediaTokenExpiry: mediaTokenExpiry,
          );
        },
        save: (c) async => saved.add(c),
        onUnauthorized: () => unauthorized++,
        getDeviceProfile: getDeviceProfile,
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

  test(
      'attaches device profile header once probe resolves, sends without when null',
      () async {
    DeviceProfile? currentProfile;
    final client = build(getDeviceProfile: () => currentProfile);

    await client.request(documentNodeQueryMydiaInstanceIdentity);
    expect(transport.calls.single.deviceProfile, isNull);

    const profile = DeviceProfile.webDefault();
    currentProfile = profile;

    await client.request(documentNodeQueryMydiaInstanceIdentity);
    expect(transport.calls.length, 2);
    expect(transport.calls.last.deviceProfile, profile.toHeaderValue());
  });

  group('media token', () {
    test('refreshes media token proactively when within 1 hour of expiry',
        () async {
      final now = DateTime.now();
      final halfHourFromNow = now.add(const Duration(minutes: 30));
      final tomorrow = DateTime.parse(
        now.add(const Duration(hours: 24)).toIso8601String(),
      );

      transport.handlers['RefreshMediaToken'] = (vars) => {
            'refreshMediaToken': {
              'token': 'fresh-media',
              'expiresAt': tomorrow.toIso8601String(),
              'permissions': ['stream'],
              '__typename': 'MediaToken',
            },
          };

      final client = build(
        mediaToken: 'old-media',
        mediaTokenExpiry: halfHourFromNow,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'fresh-media');
      expect(
        transport.calls.where((c) => c.operation == 'RefreshMediaToken'),
        hasLength(1),
      );
      expect(
        transport.calls
            .firstWhere((c) => c.operation == 'RefreshMediaToken')
            .vars,
        {'token': 'old-media'},
      );
      expect(saved.single.mediaToken, 'fresh-media');
      expect(saved.single.mediaTokenExpiry, tomorrow);
      expect((await client.credentials()).mediaToken, 'fresh-media');
    });

    test('buildMediaUrl appends token parameter', () async {
      final client = build(
        mediaToken: 'media-123',
        mediaTokenExpiry: DateTime.now().add(const Duration(hours: 2)),
      );

      final urlWithoutQuery = await client.buildMediaUrl(
        'https://media.example',
        '/video/stream.m3u8',
      );
      expect(
        urlWithoutQuery,
        'https://media.example/video/stream.m3u8?token=media-123',
      );

      final urlWithQuery = await client.buildMediaUrl(
        'https://media.example',
        '/video/stream.m3u8?profile=hd',
      );
      expect(
        urlWithQuery,
        'https://media.example/video/stream.m3u8?profile=hd&token=media-123',
      );

      final clientNoToken = build(mediaToken: null);
      final urlNoToken = await clientNoToken.buildMediaUrl(
        'https://media.example',
        '/video/stream.m3u8',
      );
      expect(urlNoToken, 'https://media.example/video/stream.m3u8');
    });

    test('does not refresh when expiry is more than 1 hour away', () async {
      final twoHoursFromNow = DateTime.now().add(const Duration(hours: 2));
      final client = build(
        mediaToken: 'valid-media',
        mediaTokenExpiry: twoHoursFromNow,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'valid-media');
      expect(
        transport.calls.where((c) => c.operation == 'RefreshMediaToken'),
        isEmpty,
      );
      expect(saved, isEmpty);
    });

    test('refreshes when media token exists but expiry is null', () async {
      final tomorrow = DateTime.parse(
        DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
      );
      transport.handlers['RefreshMediaToken'] = (vars) => {
            'refreshMediaToken': {
              'token': 'fresh-media',
              'expiresAt': tomorrow.toIso8601String(),
              'permissions': ['stream'],
              '__typename': 'MediaToken',
            },
          };

      final client = build(
        mediaToken: 'old-media',
        mediaTokenExpiry: null,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'fresh-media');
      expect(
        transport.calls.where((c) => c.operation == 'RefreshMediaToken'),
        hasLength(1),
      );
    });

    test('returns existing token if refresh fails but token is not yet expired',
        () async {
      final halfHourFromNow = DateTime.now().add(const Duration(minutes: 30));
      transport.handlers['RefreshMediaToken'] =
          (_) => throw const SourceException.unreachable();

      final client = build(
        mediaToken: 'old-media',
        mediaTokenExpiry: halfHourFromNow,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'old-media');
    });

    test(
        'media token returns existing token if refresh fails and expiry is null',
        () async {
      transport.handlers['RefreshMediaToken'] =
          (_) => throw const SourceException.unreachable();

      final client = build(
        mediaToken: 'legacy-media',
        mediaTokenExpiry: null,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'legacy-media');
    });

    test('returns null if refresh fails and token is expired', () async {
      final expired = DateTime.now().subtract(const Duration(minutes: 10));
      transport.handlers['RefreshMediaToken'] =
          (_) => throw const SourceException.unreachable();

      final client = build(
        mediaToken: 'expired-media',
        mediaTokenExpiry: expired,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, isNull);
    });

    test('stores null expiry when refreshed expiresAt is unparseable',
        () async {
      final oldExpiry = DateTime.now().add(const Duration(minutes: 10));
      transport.handlers['RefreshMediaToken'] = (_) => {
            'refreshMediaToken': {
              'token': 'fresh-token',
              'expiresAt': 'not-a-valid-date',
              'permissions': ['stream'],
              '__typename': 'MediaToken',
            },
          };

      final client = build(
        mediaToken: 'old-token',
        mediaTokenExpiry: oldExpiry,
      );

      final token = await client.ensureValidMediaToken();
      expect(token, 'fresh-token');
      expect(saved.last.mediaToken, 'fresh-token');
      expect(saved.last.mediaTokenExpiry, isNull);
      expect((await client.credentials()).mediaTokenExpiry, isNull);
    });

    test('refresh retains mediaToken fields updated concurrently', () async {
      transport.validTokens = {'access', 'fresh-access'};
      final refreshCompleter = Completer<Map<String, dynamic>>();
      transport.handlers['RefreshAccessToken'] = (_) => refreshCompleter.future;

      var rejectedOnce = false;
      transport.handlers['GuestInstanceIdentity'] = (_) {
        if (!rejectedOnce) {
          rejectedOnce = true;
          throw const SourceException.unauthorized();
        }
        return {
          'serverCompatibility': {'instanceId': 'inst-2'}
        };
      };

      final client = build(mediaToken: 'initial-media');
      final requestFuture =
          client.request(documentNodeQueryMydiaInstanceIdentity);

      await Future<void>.delayed(Duration.zero);

      // Concurrently update media token during the RefreshAccessToken await
      transport.handlers['RefreshMediaToken'] = (_) => {
            'refreshMediaToken': {
              'token': 'newer-media',
              'expiresAt': DateTime.now()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
              'permissions': ['stream'],
              '__typename': 'MediaToken',
            },
          };
      await client.ensureValidMediaToken();

      refreshCompleter.complete({
        'refreshAccessToken': {'token': 'fresh-access', 'expiresAt': null},
      });

      await requestFuture;

      final current = await client.credentials();
      expect(current.accessToken, 'fresh-access');
      expect(current.mediaToken, 'newer-media');
    });

    test('returns null when no media token exists', () async {
      final client = build(mediaToken: null);
      final token = await client.ensureValidMediaToken();
      expect(token, isNull);
      expect(
        transport.calls.where((c) => c.operation == 'RefreshMediaToken'),
        isEmpty,
      );
    });
  });

  group('server compatibility', () {
    test(
        'fetches server compatibility declaration and handles older servers returning null',
        () async {
      transport.handlers['ServerCompatibility'] = (_) => {
            'serverCompatibility': {
              'version': '1.2.3',
              'minPlayerVersion': '1.0.0',
              'recommendedPlayerVersion': '1.2.0',
              '__typename': 'ServerCompatibility',
            },
            '__typename': 'RootQueryType',
          };

      final client = build();
      final info = await client.fetchCompatibility();

      expect(info, isA<ServerCompatibilityInfo>());
      expect(info!.version, '1.2.3');
      expect(info.minPlayerVersion, '1.0.0');
      expect(info.recommendedPlayerVersion, '1.2.0');
      expect(
        transport.calls.where((c) => c.operation == 'ServerCompatibility'),
        hasLength(1),
      );

      // Gracefully handles responses without explicit __typename
      transport.handlers['ServerCompatibility'] = (_) => {
            'serverCompatibility': {
              'version': '2.0.0',
              'minPlayerVersion': '1.5.0',
              'recommendedPlayerVersion': '2.0.0',
            },
          };
      final infoNoTypename = await client.fetchCompatibility();
      expect(infoNoTypename, isNotNull);
      expect(infoNoTypename!.version, '2.0.0');

      // Server returns null for compatibility
      transport.handlers['ServerCompatibility'] = (_) => {
            'serverCompatibility': null,
            '__typename': 'RootQueryType',
          };

      expect(await client.fetchCompatibility(), isNull);
    });

    test('returns null on transport failure or unknown field error', () async {
      final client = build();

      // Unknown field error (older server without this field)
      transport.handlers['ServerCompatibility'] = (_) =>
          throw const SourceException.server(
              'Cannot query field "serverCompatibility"');
      expect(await client.fetchCompatibility(), isNull);

      // Transport failure / unreachable
      transport.handlers['ServerCompatibility'] =
          (_) => throw const SourceException.unreachable();
      expect(await client.fetchCompatibility(), isNull);
    });
  });
}
