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
