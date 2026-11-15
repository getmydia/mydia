import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart'
    show GoogleSignInException, GoogleSignInExceptionCode;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/google_auth.dart';
import 'package:player/core/backup/cloud/google_oauth_flows.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/real_http.dart';

const _tokenUrl = 'https://oauth2.googleapis.com/token';
const _deviceUrl = 'https://oauth2.googleapis.com/device/code';

/// An unsigned JWT whose payload carries [email], the shape of the
/// `id_token` Google returns alongside the access token.
String _idToken(String email) {
  String seg(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'RS256'})}.${seg({'email': email})}.c2ln';
}

http.Response _json(int status, Map<String, Object?> body) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

Map<String, Object?> _grant({
  String access = 'at-1',
  String? refresh = 'rt-1',
  String email = 'viewer@example.test',
  int expiresIn = 3599,
}) =>
    {
      'access_token': access,
      'expires_in': expiresIn,
      if (refresh != null) 'refresh_token': refresh,
      'id_token': _idToken(email),
      'token_type': 'Bearer',
    };

String _b64NoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

void main() {
  useRealHttp();

  late MockAuthStorage storage;

  setUp(() => storage = MockAuthStorage());

  GoogleTokenAuth tokenAuth(
    http.Client client, {
    DateTime Function()? now,
    String clientKind = 'desktop',
  }) =>
      GoogleTokenAuth(
        storage: storage,
        client: client,
        clientId: 'cid',
        clientSecret: 'csecret',
        clientKind: clientKind,
        now: now,
      );

  Map<String, Object?> stored() =>
      jsonDecode(storage.contents[googleDriveStorageKey]!)
          as Map<String, Object?>;

  test('pkce_challenge_is_s256_of_verifier', () {
    final verifier = LoopbackPkceFlow.newVerifier(Random(7));
    // 64 bytes base64url without padding is 86 characters.
    expect(verifier, hasLength(86));
    expect(verifier, isNot(contains('=')));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(verifier), isTrue);
    expect(
      LoopbackPkceFlow.challengeFor(verifier),
      _b64NoPad(sha256.convert(ascii.encode(verifier)).bytes),
    );
  });

  group('loopback', () {
    Future<int> hitRedirect(Uri redirect) async {
      final io = HttpClient();
      try {
        final req = await io.getUrl(redirect);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      } finally {
        io.close(force: true);
      }
    }

    test('loopback_exchanges_code_and_stores_refresh_token', () async {
      late Uri authUrl;
      final client = MockClient((req) async {
        expect(req.url.toString(), _tokenUrl);
        final form = Uri.splitQueryString(req.body);
        expect(form['grant_type'], 'authorization_code');
        expect(form['code'], 'the-code');
        expect(form['client_id'], 'cid');
        expect(form['client_secret'], 'csecret');
        expect(form['redirect_uri'], authUrl.queryParameters['redirect_uri']);
        expect(
          LoopbackPkceFlow.challengeFor(form['code_verifier']!),
          authUrl.queryParameters['code_challenge'],
        );
        return _json(200, _grant());
      });
      final auth = tokenAuth(client);

      await LoopbackPkceFlow().signIn(
        auth,
        launch: (url) async {
          authUrl = url;
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          unawaited(
            hitRedirect(
              redirect.replace(
                queryParameters: {
                  'code': 'the-code',
                  'state': url.queryParameters['state'],
                },
              ),
            ),
          );
          return true;
        },
      );

      expect(authUrl.origin, 'https://accounts.google.com');
      expect(authUrl.path, '/o/oauth2/v2/auth');
      final q = authUrl.queryParameters;
      expect(q['client_id'], 'cid');
      expect(q['response_type'], 'code');
      expect(q['code_challenge_method'], 'S256');
      expect(q['access_type'], 'offline');
      expect(
        q['scope']!.split(' ').toSet(),
        {'openid', 'email', 'https://www.googleapis.com/auth/drive.appdata'},
      );
      final redirect = Uri.parse(q['redirect_uri']!);
      expect(redirect.host, '127.0.0.1');
      expect(redirect.port, greaterThan(0));

      expect(stored(), {
        'email': 'viewer@example.test',
        'refreshToken': 'rt-1',
        'clientKind': 'desktop',
      });
      expect(await auth.currentEmail(), 'viewer@example.test');
      expect(await auth.accessToken(), 'at-1');
    });

    test('loopback_rejects_mismatched_state', () async {
      var tokenCalls = 0;
      final client = MockClient((req) async {
        tokenCalls++;
        return _json(200, _grant());
      });
      final auth = tokenAuth(client);
      int? forgedStatus;
      int? tokenCallsAfterForged;
      bool? storedAfterForged;

      await LoopbackPkceFlow().signIn(
        auth,
        launch: (url) async {
          final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
          unawaited(() async {
            // A forged redirect first: refused, and the listener stays up.
            forgedStatus = await hitRedirect(
              redirect.replace(
                queryParameters: {'code': 'forged-code', 'state': 'forged'},
              ),
            );
            tokenCallsAfterForged = tokenCalls;
            storedAfterForged = storage.containsKey(googleDriveStorageKey);
            await hitRedirect(
              redirect.replace(
                queryParameters: {
                  'code': 'the-code',
                  'state': url.queryParameters['state'],
                },
              ),
            );
          }());
          return true;
        },
      );

      expect(forgedStatus, HttpStatus.badRequest);
      expect(tokenCallsAfterForged, 0);
      expect(storedAfterForged, isFalse);
      // The matching redirect then completed the sign-in.
      expect(tokenCalls, 1);
      expect(stored()['refreshToken'], 'rt-1');
    });
  });

  group('device code', () {
    late DateTime clock;
    late List<Duration> delays;

    setUp(() {
      clock = DateTime.utc(2026, 11, 14, 12);
      delays = [];
    });

    DeviceCodeFlow flow() => DeviceCodeFlow(
          now: () => clock,
          delay: (d) async {
            delays.add(d);
            clock = clock.add(d);
          },
        );

    http.Response deviceCode({int interval = 5, int expiresIn = 1800}) =>
        _json(200, {
          'device_code': 'dc-1',
          'user_code': 'ABCD-EFGH',
          'verification_url': 'https://www.google.com/device',
          'expires_in': expiresIn,
          'interval': interval,
        });

    MockClient scripted(List<http.Response> polls, {http.Response? device}) {
      var i = 0;
      return MockClient((req) async {
        if (req.url.toString() == _deviceUrl) {
          final form = Uri.splitQueryString(req.body);
          expect(form['client_id'], 'cid');
          expect(
            form['scope']!.split(' ').toSet(),
            {
              'openid',
              'email',
              'https://www.googleapis.com/auth/drive.appdata'
            },
          );
          return device ?? deviceCode();
        }
        expect(req.url.toString(), _tokenUrl);
        final form = Uri.splitQueryString(req.body);
        expect(
          form['grant_type'],
          'urn:ietf:params:oauth:grant-type:device_code',
        );
        expect(form['device_code'], 'dc-1');
        expect(form['client_secret'], 'csecret');
        return polls[i++];
      });
    }

    test('device_code_pending_then_done', () async {
      final auth = tokenAuth(
        scripted([
          _json(428, {'error': 'authorization_pending'}),
          _json(428, {'error': 'authorization_pending'}),
          _json(200, _grant(access: 'tv-at', refresh: 'tv-rt')),
        ]),
        now: () => clock,
        clientKind: 'tv',
      );

      final states = await flow().signIn(auth).toList();

      expect(states, hasLength(2));
      final code = states.first as DeviceCodePending;
      expect(code.userCode, 'ABCD-EFGH');
      expect(code.verificationUrl, Uri.parse('https://www.google.com/device'));
      expect(
        code.expiresAt,
        DateTime.utc(2026, 11, 14, 12).add(const Duration(seconds: 1800)),
      );
      expect(states.last, isA<DeviceCodeDone>());
      expect(delays, everyElement(const Duration(seconds: 5)));
      expect(delays, hasLength(3));
      expect(stored(), {
        'email': 'viewer@example.test',
        'refreshToken': 'tv-rt',
        'clientKind': 'tv',
      });
      expect(await auth.accessToken(), 'tv-at');
    });

    test('device_code_slow_down_adds_5s', () async {
      final auth = tokenAuth(
        scripted([
          _json(428, {'error': 'authorization_pending'}),
          _json(403, {'error': 'slow_down'}),
          _json(428, {'error': 'authorization_pending'}),
          _json(200, _grant()),
        ]),
        now: () => clock,
        clientKind: 'tv',
      );

      final states = await flow().signIn(auth).toList();

      expect(states.last, isA<DeviceCodeDone>());
      expect(delays, const [
        Duration(seconds: 5),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 10),
      ]);
    });

    test('device_code_expired_and_denied', () async {
      // Expiry by the clock: never polls past expires_in.
      final pending = _json(428, {'error': 'authorization_pending'});
      final expiring = tokenAuth(
        scripted(
          List.filled(10, pending),
          device: deviceCode(interval: 5, expiresIn: 12),
        ),
        now: () => clock,
        clientKind: 'tv',
      );
      final expired = await flow().signIn(expiring).toList();
      expect(expired.last, isA<DeviceCodeExpired>());
      // Polls at +5 s and +10 s; the wake at +15 s is past the 12 s expiry.
      expect(delays, hasLength(3));
      expect(storage.containsKey(googleDriveStorageKey), isFalse);

      // Expiry reported by Google.
      delays.clear();
      final googleExpired = tokenAuth(
        scripted([
          _json(400, {'error': 'expired_token'}),
        ]),
        now: () => clock,
        clientKind: 'tv',
      );
      expect(
        (await flow().signIn(googleExpired).toList()).last,
        isA<DeviceCodeExpired>(),
      );

      // The viewer declined on their phone.
      final denied = tokenAuth(
        scripted([
          _json(428, {'error': 'authorization_pending'}),
          _json(403, {'error': 'access_denied'}),
        ]),
        now: () => clock,
        clientKind: 'tv',
      );
      final deniedStates = await flow().signIn(denied).toList();
      expect(deniedStates.last, isA<DeviceCodeDenied>());
      expect(storage.containsKey(googleDriveStorageKey), isFalse);
    });

    test('device_code_cancel_stops_polling_immediately', () async {
      final delayStarted = Completer<void>();
      final neverFinishes = Completer<void>();
      var tokenPolls = 0;
      final client = MockClient((req) async {
        if (req.url.toString() == _deviceUrl) return deviceCode(interval: 30);
        tokenPolls++;
        return _json(428, {'error': 'authorization_pending'});
      });
      final auth = tokenAuth(client, now: () => clock, clientKind: 'tv');
      final cancellingFlow = DeviceCodeFlow(
        now: () => clock,
        delay: (_) {
          if (!delayStarted.isCompleted) delayStarted.complete();
          return neverFinishes.future;
        },
      );

      final states = <DeviceCodeState>[];
      final sub = cancellingFlow.signIn(auth).listen(states.add);
      await delayStarted.future;
      expect(states, [isA<DeviceCodePending>()]);

      // Must complete immediately without waiting for `neverFinishes`.
      await sub.cancel().timeout(const Duration(milliseconds: 500));
      expect(tokenPolls, 0);
    });
  });

  test('refresh_invalid_grant_reports_signed_out', () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'viewer@example.test',
        'refreshToken': 'revoked-rt',
        'clientKind': 'desktop',
      }),
    });
    final client = MockClient((req) async {
      expect(req.url.toString(), _tokenUrl);
      final form = Uri.splitQueryString(req.body);
      expect(form['grant_type'], 'refresh_token');
      expect(form['refresh_token'], 'revoked-rt');
      return _json(400, {'error': 'invalid_grant'});
    });
    final auth = tokenAuth(client);

    await expectLater(
      auth.accessToken(),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut),
      ),
    );
    expect(storage.containsKey(googleDriveStorageKey), isFalse);
    expect(await auth.currentEmail(), isNull);
  });

  test('access_token_cached_until_expiry', () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'viewer@example.test',
        'refreshToken': 'rt-1',
        'clientKind': 'desktop',
      }),
    });
    var clock = DateTime.utc(2026, 11, 14, 12);
    var refreshes = 0;
    final client = MockClient((req) async {
      refreshes++;
      return _json(200, {
        'access_token': 'at-$refreshes',
        'expires_in': 3600,
        'token_type': 'Bearer',
      });
    });
    final auth = tokenAuth(client, now: () => clock);

    expect(await auth.accessToken(), 'at-1');
    clock = clock.add(const Duration(minutes: 50));
    expect(await auth.accessToken(), 'at-1');
    expect(refreshes, 1);

    // forceRefresh skips the cache even while it is still fresh.
    expect(await auth.accessToken(forceRefresh: true), 'at-2');
    expect(refreshes, 2);

    // Past expiry the cached token is not handed out.
    clock = clock.add(const Duration(minutes: 61));
    expect(await auth.accessToken(), 'at-3');
    expect(refreshes, 3);
    // The refresh token is kept when Google does not rotate it.
    expect(stored()['refreshToken'], 'rt-1');
  });

  test('access token with nothing stored reports signed out', () async {
    final auth = tokenAuth(MockClient((_) async => fail('no request')));
    await expectLater(
      auth.accessToken(),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut),
      ),
    );
  });

  test('signOut revokes the refresh token and clears storage', () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'viewer@example.test',
        'refreshToken': 'rt-1',
        'clientKind': 'desktop',
      }),
    });
    final revoked = <String>[];
    final client = MockClient((req) async {
      expect(req.url.toString(), 'https://oauth2.googleapis.com/revoke');
      revoked.add(Uri.splitQueryString(req.body)['token']!);
      return http.Response('', 200);
    });
    final auth = tokenAuth(client);

    await auth.signOut();

    expect(revoked, ['rt-1']);
    expect(storage.containsKey(googleDriveStorageKey), isFalse);
  });

  group('googleFlowFor', () {
    const all = GoogleClientDefines(
      android: 'a',
      ios: 'i',
      desktop: 'd',
      desktopSecret: 'ds',
      tv: 't',
      tvSecret: 'ts',
    );

    GoogleFlowKind? pick(
      GoogleTargetPlatform platform, {
      bool directional = false,
      GoogleClientDefines defines = all,
    }) =>
        googleFlowFor(
          platform: platform,
          directionalPrimary: directional,
          defines: defines,
        );

    test('picks one flow per platform', () {
      expect(pick(GoogleTargetPlatform.android), GoogleFlowKind.signIn);
      expect(
        pick(GoogleTargetPlatform.android, directional: true),
        GoogleFlowKind.deviceCode,
      );
      expect(pick(GoogleTargetPlatform.ios), GoogleFlowKind.signIn);
      expect(pick(GoogleTargetPlatform.desktop), GoogleFlowKind.loopback);
      expect(pick(GoogleTargetPlatform.web), isNull);
    });

    test('an empty define hides Google Drive on that platform', () {
      const none = GoogleClientDefines(
        android: '',
        ios: '',
        desktop: 'd',
        desktopSecret: '',
        tv: '',
        tvSecret: 'ts',
      );
      expect(pick(GoogleTargetPlatform.android, defines: none), isNull);
      expect(
        pick(GoogleTargetPlatform.android, directional: true, defines: none),
        isNull,
      );
      expect(pick(GoogleTargetPlatform.ios, defines: none), isNull);
      expect(pick(GoogleTargetPlatform.desktop, defines: none), isNull);
    });
  });

  test('completeSignIn never falls back to the other client grant', () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'tv@example.test',
        'refreshToken': 'tv-rt',
        'clientKind': 'tv',
      }),
    });
    final auth = tokenAuth(MockClient((_) async => fail('no request')));

    await expectLater(
      auth.completeSignIn({'access_token': 'at', 'expires_in': 3600}),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut)
            .having((e) => e.code, 'code', 'no_refresh_token'),
      ),
    );
    expect(stored()['refreshToken'], 'tv-rt');
  });

  test('completeSignIn without drive.appdata is signed out, storing nothing',
      () async {
    final auth = tokenAuth(MockClient((_) async => fail('no request')));

    await expectLater(
      auth.completeSignIn({..._grant(), 'scope': 'openid email'}),
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut)
            .having((e) => e.code, 'code', googleScopeMissingCode),
      ),
    );
    expect(storage.containsKey(googleDriveStorageKey), isFalse);

    // The full grant, as Google lists it, is accepted.
    expect(
        await auth.completeSignIn({
          ..._grant(),
          'scope': '$googleDriveAppDataScope openid '
              'https://www.googleapis.com/auth/userinfo.email',
        }),
        'viewer@example.test');
    expect(stored()['refreshToken'], 'rt-1');
  });

  test('completeSignIn falls back to userinfo when id_token lacks email',
      () async {
    final auth = tokenAuth(MockClient((req) async {
      expect(req.url.toString(),
          'https://openidconnect.googleapis.com/v1/userinfo');
      expect(req.headers['authorization'], 'Bearer at-1');
      return _json(200, {'email': 'userinfo@example.test'});
    }));

    final grant = _grant()
      ..remove('id_token')
      ..['scope'] = googleDriveAppDataScope;
    expect(await auth.completeSignIn(grant), 'userinfo@example.test');
    expect(await auth.currentEmail(), 'userinfo@example.test');
    expect(stored()['email'], 'userinfo@example.test');
  });

  test('cancelled completeSignIn while awaiting userinfo never overwrites',
      () async {
    final staleUserInfoStarted = Completer<void>();
    final staleUserInfoGate = Completer<void>();
    const staleToken = 'at-stale';
    final client = MockClient((req) async {
      if (req.url.toString() == _deviceUrl) {
        return _json(200, {
          'device_code': 'dc-stale',
          'user_code': 'STALE-1234',
          'verification_url': 'https://www.google.com/device',
          'expires_in': 1800,
          'interval': 1,
        });
      }
      if (req.url.toString() == _tokenUrl) {
        return _json(200, {
          'access_token': staleToken,
          'expires_in': 3599,
          'refresh_token': 'rt-stale',
          'scope': googleDriveAppDataScope,
          'token_type': 'Bearer',
        });
      }
      expect(
        req.url.toString(),
        'https://openidconnect.googleapis.com/v1/userinfo',
      );
      if (!staleUserInfoStarted.isCompleted) staleUserInfoStarted.complete();
      await staleUserInfoGate.future;
      return _json(200, {'email': 'stale@example.test'});
    });
    final auth = tokenAuth(client, clientKind: 'tv');
    final deviceFlow = DeviceCodeFlow(delay: (_) async {});

    final states = <DeviceCodeState>[];
    final errors = <Object>[];
    final sub = deviceFlow.signIn(auth).listen(states.add, onError: errors.add);
    await staleUserInfoStarted.future;

    // Cancel the first attempt while /userinfo is in flight, then finish a
    // newer sign-in.
    await sub.cancel();
    await auth.completeSignIn({
      ..._grant(
        access: 'at-fresh',
        refresh: 'rt-fresh',
        email: 'fresh@example.test',
      ),
      'scope': googleDriveAppDataScope,
    });

    staleUserInfoGate.complete();
    await Future<void>.delayed(Duration.zero);

    expect(errors, isEmpty);
    expect(states, [isA<DeviceCodePending>()]);
    expect(await auth.currentEmail(), 'fresh@example.test');
    expect(stored()['refreshToken'], 'rt-fresh');
    expect(await auth.accessToken(), 'at-fresh');
  });

  test('paused first storage write never overwrites newer sign-in or cache',
      () async {
    final pausing = _PausingAuthStorage()..pauseFirstWrite = Completer<void>();
    final auth = GoogleTokenAuth(
      storage: pausing,
      client: MockClient((_) async => fail('no request')),
      clientId: 'cid',
      clientSecret: 'csecret',
      clientKind: 'tv',
    );

    var firstCancelled = false;
    final first = auth.completeSignIn(
      {
        ..._grant(
          access: 'at-stale',
          refresh: 'rt-stale',
          email: 'stale@example.test',
        ),
        'scope': googleDriveAppDataScope,
      },
      isCancelled: () => firstCancelled,
    );
    await pausing.firstWriteStarted.future;

    // Cancel the first attempt while its AuthStorage.write is in flight, then
    // start a newer sign-in.
    firstCancelled = true;
    final second = auth.completeSignIn({
      ..._grant(
        access: 'at-fresh',
        refresh: 'rt-fresh',
        email: 'fresh@example.test',
      ),
      'scope': googleDriveAppDataScope,
    });
    await Future<void>.delayed(Duration.zero);
    // Serialised storage access holds the newer write until the in-flight write
    // finishes rather than racing out of order.
    expect(pausing.writeCalls, 1);

    pausing.pauseFirstWrite!.complete();
    await expectLater(
      first,
      throwsA(isA<BackupRelayException>()
          .having((e) => e.code, 'code', 'cancelled')),
    );
    expect(await second, 'fresh@example.test');
    expect(await auth.currentEmail(), 'fresh@example.test');
    final saved = jsonDecode(pausing.contents[googleDriveStorageKey]!)
        as Map<String, dynamic>;
    expect(saved['refreshToken'], 'rt-fresh');
    expect(await auth.accessToken(), 'at-fresh');
  });

  test('standalone cancel while storage write is paused rolls back storage',
      () async {
    final pausing = _PausingAuthStorage()..pauseFirstWrite = Completer<void>();
    final auth = GoogleTokenAuth(
      storage: pausing,
      client: MockClient((_) async => fail('no request')),
      clientId: 'cid',
      clientSecret: 'csecret',
      clientKind: 'tv',
    );

    var cancelled = false;
    final pending = auth.completeSignIn(
      {
        ..._grant(
          access: 'at-stale',
          refresh: 'rt-stale',
          email: 'stale@example.test',
        ),
        'scope': googleDriveAppDataScope,
      },
      isCancelled: () => cancelled,
    );
    await pausing.firstWriteStarted.future;

    cancelled = true;
    pausing.pauseFirstWrite!.complete();

    await expectLater(
      pending,
      throwsA(isA<BackupRelayException>()
          .having((e) => e.code, 'code', 'cancelled')),
    );
    expect(pausing.containsKey(googleDriveStorageKey), isFalse);
    expect(await auth.currentEmail(), isNull);
  });

  test('paused write restores prior grant even when superseding sign-in fails',
      () async {
    final pausing = _PausingAuthStorage()
      ..seedData({
        googleDriveStorageKey: jsonEncode({
          'email': 'prior@example.test',
          'refreshToken': 'rt-prior',
          'clientKind': 'tv',
        }),
      })
      ..pauseFirstWrite = Completer<void>();
    final auth = GoogleTokenAuth(
      storage: pausing,
      client: MockClient((_) async => fail('no request')),
      clientId: 'cid',
      clientSecret: 'csecret',
      clientKind: 'tv',
    );

    final first = auth.completeSignIn({
      ..._grant(
        access: 'at-stale',
        refresh: 'rt-stale',
        email: 'stale@example.test',
      ),
      'scope': googleDriveAppDataScope,
    });
    await pausing.firstWriteStarted.future;

    // A newer attempt supersedes generation, then fails before replacing storage.
    await expectLater(
      auth.completeSignIn({..._grant(), 'scope': 'openid email'}),
      throwsA(isA<BackupRelayException>()
          .having((e) => e.code, 'code', googleScopeMissingCode)),
    );

    pausing.pauseFirstWrite!.complete();
    await expectLater(
      first,
      throwsA(isA<BackupRelayException>()
          .having((e) => e.code, 'code', 'cancelled')),
    );

    final saved = jsonDecode(pausing.contents[googleDriveStorageKey]!)
        as Map<String, dynamic>;
    expect(saved['email'], 'prior@example.test');
    expect(saved['refreshToken'], 'rt-prior');
  });

  test(
      'in-flight refresh read before newer sign-in commits keeps newer grant on invalid_grant',
      () async {
    // Seed grant A without email so B's grant (without id_token) falls through
    // to /userinfo before writing grant B.
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'refreshToken': 'rt-a',
        'clientKind': 'desktop',
      }),
    });
    final userInfoStarted = Completer<void>();
    final userInfoGate = Completer<void>();
    final refreshStarted = Completer<void>();
    final refreshGate = Completer<void>();
    final client = MockClient((req) async {
      if (req.url.toString() ==
          'https://openidconnect.googleapis.com/v1/userinfo') {
        if (!userInfoStarted.isCompleted) userInfoStarted.complete();
        await userInfoGate.future;
        return _json(200, {'email': 'b@example.test'});
      }
      if (req.url.toString() == _tokenUrl) {
        final form = Uri.splitQueryString(req.body);
        expect(form['refresh_token'], 'rt-a');
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        await refreshGate.future;
        return _json(400, {'error': 'invalid_grant'});
      }
      fail('unexpected request: ${req.url}');
    });
    final auth = tokenAuth(client);

    final signInB = auth.completeSignIn(
      _grant(access: 'at-b', refresh: 'rt-b')
        ..remove('id_token')
        ..['scope'] = googleDriveAppDataScope,
    );
    await userInfoStarted.future;

    // Refresh starts while B is in /userinfo (after B bumped generation,
    // before B commits grant B) and reads grant A.
    final staleRefresh = auth.accessToken();
    await refreshStarted.future;

    userInfoGate.complete();
    expect(await signInB, 'b@example.test');

    refreshGate.complete();
    await expectLater(
      staleRefresh,
      throwsA(
        isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut)
            .having((e) => e.code, 'code', 'invalid_grant'),
      ),
    );

    expect(stored()['email'], 'b@example.test');
    expect(stored()['refreshToken'], 'rt-b');
    expect(await auth.currentEmail(), 'b@example.test');
    expect(await auth.accessToken(), 'at-b');
  });

  test(
      'accessToken(forceRefresh: true) after newer sign-in refreshes new grant',
      () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'a@example.test',
        'refreshToken': 'rt-a',
        'clientKind': 'desktop',
      }),
    });
    final refreshAStarted = Completer<void>();
    final refreshAGate = Completer<void>();
    final refreshBStarted = Completer<void>();
    final refreshBGate = Completer<void>();
    var refreshBCount = 0;
    final client = MockClient((req) async {
      expect(req.url.toString(), _tokenUrl);
      final rt = Uri.splitQueryString(req.body)['refresh_token'];
      if (rt == 'rt-a') {
        if (!refreshAStarted.isCompleted) refreshAStarted.complete();
        await refreshAGate.future;
        return _json(200, {'access_token': 'at-a-stale', 'expires_in': 3600});
      }
      if (rt == 'rt-b') {
        refreshBCount++;
        if (!refreshBStarted.isCompleted) refreshBStarted.complete();
        await refreshBGate.future;
        return _json(200, {'access_token': 'at-b-fresh', 'expires_in': 3600});
      }
      fail('unexpected refresh_token: $rt');
    });
    final auth = tokenAuth(client);

    final first = auth.accessToken();
    await refreshAStarted.future;

    await auth.completeSignIn({
      ..._grant(access: 'at-b', refresh: 'rt-b', email: 'b@example.test'),
      'scope': googleDriveAppDataScope,
    });

    final forced = auth.accessToken(forceRefresh: true);
    await refreshBStarted.future;

    refreshAGate.complete();
    final firstResult = await first;
    expect(firstResult, 'at-b');

    // A's completion must not clear B's in-flight _refreshing slot.
    final coalesced = auth.accessToken(forceRefresh: true);

    refreshBGate.complete();
    expect(await forced, 'at-b-fresh');
    expect(await coalesced, 'at-b-fresh');
    expect(refreshBCount, 1);
    expect(await auth.accessToken(), 'at-b-fresh');
  });

  test(
      'in-flight refresh finishing after signOut never caches or returns token',
      () async {
    storage.seedData({
      googleDriveStorageKey: jsonEncode({
        'email': 'a@example.test',
        'refreshToken': 'rt-a',
        'clientKind': 'desktop',
      }),
    });
    final refreshStarted = Completer<void>();
    final refreshGate = Completer<void>();
    final client = MockClient((req) async {
      if (req.url.toString() == _tokenUrl) {
        if (!refreshStarted.isCompleted) refreshStarted.complete();
        await refreshGate.future;
        return _json(200, {'access_token': 'at-a-stale', 'expires_in': 3600});
      }
      if (req.url.toString() == 'https://oauth2.googleapis.com/revoke') {
        return http.Response('', 200);
      }
      fail('unexpected request: ${req.url}');
    });
    final auth = tokenAuth(client);

    final pending = auth.accessToken();
    await refreshStarted.future;

    await auth.signOut();
    refreshGate.complete();

    await expectLater(
      pending,
      throwsA(isA<BackupRelayException>()
          .having((e) => e.kind, 'kind', BackupRelayError.signedOut)),
    );
    await expectLater(
      auth.accessToken(),
      throwsA(isA<BackupRelayException>()
          .having((e) => e.kind, 'kind', BackupRelayError.signedOut)),
    );
  });

  test('GoogleSignInAuth is constructible without touching the plugin', () {
    final auth = GoogleSignInAuth(
      storage: storage,
      client: MockClient((_) async => fail('no request')),
      clientId: 'ios-cid',
    );
    expect(auth, isA<GoogleAuth>());
  });

  group('GoogleSignInAuth', () {
    late _FakeSignInBackend backend;

    setUp(() {
      backend = _FakeSignInBackend();
      storage.seedData({
        googleDriveStorageKey: jsonEncode({'email': 'viewer@example.test'}),
      });
    });

    GoogleSignInAuth signInAuth({http.Client? client}) => GoogleSignInAuth(
          storage: storage,
          client: client ?? MockClient((_) async => fail('no request')),
          backend: backend,
        );

    Matcher relayError(BackupRelayError kind) => throwsA(
        isA<BackupRelayException>().having((e) => e.kind, 'kind', kind));

    test('restores the session before the first silent authorization',
        () async {
      backend.restoreResult = true;
      backend.token = 'restored-at';

      expect(await signInAuth().accessToken(), 'restored-at');
      expect(backend.calls, ['restore', 'authorize']);
      expect(storage.containsKey(googleDriveStorageKey), isTrue);
    });

    test('no session and no grant is a sign-out that clears the account',
        () async {
      backend.restoreResult = false;
      backend.token = null;

      await expectLater(
        signInAuth().accessToken(),
        relayError(BackupRelayError.signedOut),
      );
      expect(storage.containsKey(googleDriveStorageKey), isFalse);
    });

    test('a failed restore is never read as a sign-out', () async {
      backend.restoreError = const GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
      );
      backend.token = null;
      final auth = signInAuth();

      await expectLater(
          auth.accessToken(), relayError(BackupRelayError.server));
      expect(storage.containsKey(googleDriveStorageKey), isTrue);

      // The restore is tried again on the next call, and can succeed.
      backend.restoreError = null;
      backend.restoreResult = true;
      backend.token = 'later-at';
      expect(await auth.accessToken(), 'later-at');
      expect(backend.calls.where((c) => c == 'restore'), hasLength(2));
    });

    test('a platform exception maps to server or network, keeping the account',
        () async {
      backend.restoreResult = true;
      backend.authorizeError = const GoogleSignInException(
        code: GoogleSignInExceptionCode.interrupted,
      );
      final auth = signInAuth();
      await expectLater(
          auth.accessToken(), relayError(BackupRelayError.network));

      backend.authorizeError = const GoogleSignInException(
        code: GoogleSignInExceptionCode.clientConfigurationError,
      );
      await expectLater(
          auth.accessToken(), relayError(BackupRelayError.server));
      expect(storage.containsKey(googleDriveStorageKey), isTrue);
    });

    test('forceRefresh clears the last token first', () async {
      backend.restoreResult = true;
      backend.token = 'at-1';
      final auth = signInAuth();
      await auth.accessToken();
      backend.token = 'at-2';

      expect(await auth.accessToken(forceRefresh: true), 'at-2');
      expect(backend.cleared, ['at-1']);
    });

    /// Answers tokeninfo with [scope] and userinfo with [userInfo].
    MockClient googleApis(
            {String scope = 'openid email $googleDriveAppDataScope',
            http.Response? userInfo}) =>
        MockClient((req) async {
          if (req.url.path == '/tokeninfo') {
            expect(req.url.host, 'oauth2.googleapis.com');
            expect(req.url.queryParameters['access_token'], 'consent-at');
            return _json(200, {'scope': scope});
          }
          expect(req.url.toString(),
              'https://openidconnect.googleapis.com/v1/userinfo');
          expect(req.headers['authorization'], 'Bearer consent-at');
          return userInfo ?? _json(200, {'email': 'viewer@example.test'});
        });

    test('signIn stores only the email from userinfo', () async {
      storage.clear();
      backend.interactiveToken = 'consent-at';

      expect(await signInAuth(client: googleApis()).signIn(),
          'viewer@example.test');
      expect(stored(), {'email': 'viewer@example.test'});
    });

    test('signIn without drive.appdata granted is signed out, storing nothing',
        () async {
      storage.clear();
      backend.interactiveToken = 'consent-at';

      await expectLater(
        signInAuth(client: googleApis(scope: 'openid email')).signIn(),
        throwsA(isA<BackupRelayException>()
            .having((e) => e.kind, 'kind', BackupRelayError.signedOut)
            .having((e) => e.code, 'code', googleScopeMissingCode)),
      );
      expect(storage.containsKey(googleDriveStorageKey), isFalse);
    });

    test('a non-JSON userinfo body is a server error', () async {
      storage.clear();
      backend.interactiveToken = 'consent-at';
      final client = googleApis(userInfo: http.Response('<html>', 200));

      await expectLater(
        signInAuth(client: client).signIn(),
        relayError(BackupRelayError.server),
      );
      expect(storage.containsKey(googleDriveStorageKey), isFalse);
    });
  });
}

/// Scripted stand-in for the google_sign_in calls.
class _FakeSignInBackend implements GoogleSignInBackend {
  bool restoreResult = false;
  GoogleSignInException? restoreError;
  String? token;
  GoogleSignInException? authorizeError;
  String interactiveToken = 'interactive-at';
  final List<String> calls = [];
  final List<String> cleared = [];

  @override
  Future<bool> restoreSession() async {
    calls.add('restore');
    final error = restoreError;
    if (error != null) throw error;
    return restoreResult;
  }

  @override
  Future<String?> authorizationForScopes(List<String> scopes) async {
    calls.add('authorize');
    expect(scopes, googleOAuthScopes);
    final error = authorizeError;
    if (error != null) throw error;
    return token;
  }

  @override
  Future<String> authorizeScopes(List<String> scopes) async {
    calls.add('consent');
    return interactiveToken;
  }

  @override
  Future<void> clearToken(String accessToken) async => cleared.add(accessToken);

  @override
  Future<void> disconnect() async => calls.add('disconnect');
}

class _PausingAuthStorage extends MockAuthStorage {
  int writeCalls = 0;
  Completer<void>? pauseFirstWrite;
  final Completer<void> firstWriteStarted = Completer<void>();

  @override
  Future<void> write(String key, String value) async {
    writeCalls++;
    final gate = pauseFirstWrite;
    if (writeCalls == 1 && gate != null) {
      if (!firstWriteStarted.isCompleted) firstWriteStarted.complete();
      await gate.future;
    }
    await super.write(key, value);
  }
}
