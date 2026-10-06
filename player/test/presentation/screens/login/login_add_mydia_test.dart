// Every login flow (claim code, URL and password, TOTP, QR) stores the result
// as a Mydia account and leaves the legacy AuthService storage alone.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/device_info_service.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login/login_controller.dart';

import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/scripted_mydia_transport.dart';

class _FakePairing extends PairingService {
  _FakePairing(this.credentials);
  final PairingCredentials credentials;

  @override
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async =>
      PairingResult.success(credentials, isP2PMode: true);

  @override
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async =>
      PairingResult.success(credentials, isP2PMode: true);
}

/// Completes only when the test says so.
class _GatedPairing extends PairingService {
  _GatedPairing(this.credentials);
  final PairingCredentials credentials;
  final gate = Completer<void>();

  @override
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(String status)? onStatusUpdate,
  }) async {
    await gate.future;
    return PairingResult.success(credentials, isP2PMode: true);
  }
}

class _LoginSuccessAuth extends AuthService {
  _LoginSuccessAuth(MockAuthStorage storage) : super(storage: storage);

  @override
  Future<LoginOutcome> requestLogin({
    required String serverUrl,
    required String username,
    required String password,
  }) async =>
      const LoginSuccess();
}

/// Answers a password with a TOTP challenge, then the code with a grant.
class _TotpAuth extends AuthService {
  _TotpAuth(MockAuthStorage storage) : super(storage: storage);

  @override
  Future<LoginOutcome> requestLogin({
    required String serverUrl,
    required String username,
    required String password,
  }) async =>
      TotpChallenge(
        serverUrl: serverUrl,
        challengeToken: 'challenge',
        username: username,
      );

  @override
  Future<LoginGranted> requestTotp({
    required TotpChallenge challenge,
    required String code,
  }) async =>
      LoginGranted(
        serverUrl: challenge.serverUrl,
        token: 'tok',
        userId: 'u1',
        username: challenge.username,
      );
}

/// Answers a password with a grant, so the login itself succeeds.
class _GrantedAuth extends AuthService {
  _GrantedAuth(MockAuthStorage storage) : super(storage: storage);

  @override
  Future<LoginOutcome> requestLogin({
    required String serverUrl,
    required String username,
    required String password,
  }) async =>
      LoginGranted(
        serverUrl: serverUrl,
        token: 'tok',
        userId: 'u1',
        username: username,
      );
}

/// A store whose writes fail the way an unreadable disk does.
class _FailingWriteStore extends InMemorySourceStore {
  @override
  Future<void> putAccount(SourceAccountRecord record) async =>
      throw const SourceException.unreachable();
}

class _FakeDeviceInfo extends DeviceInfoService {
  @override
  Future<String> getDeviceId() async => 'device-1';
  @override
  Future<String> getDeviceName() async => 'Test Device';
  @override
  String getPlatform() => 'linux';
}

PairingCredentials _credentials(String instanceId) => PairingCredentials(
      serverUrl: 'p2p://node-$instanceId',
      deviceId: 'dev-12345678',
      mediaToken: 'media',
      accessToken: 'access',
      deviceToken: 'device',
      serverPublicKey: Uint8List(32),
      directUrls: const [],
      instanceName: 'Friends',
      instanceId: instanceId,
      // One node per server: the saver treats a shared node id as one server.
      serverNodeAddr: '{"id":"node-$instanceId","addrs":[]}',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockAuthStorage authStorage;
  late MockAuthStorage secrets;
  late InMemorySourceStore store;

  ProviderContainer containerFor({
    PairingService? pairing,
    AuthService? auth,
  }) {
    final c = ProviderContainer(overrides: [
      noDownloadsOverride,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(secrets)),
      loginDeviceInfoProvider.overrideWithValue(_FakeDeviceInfo()),
      if (pairing != null) pairingServiceProvider.overrideWithValue(pairing),
      authServiceProvider
          .overrideWithValue(auth ?? AuthService(storage: authStorage)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    authStorage = MockAuthStorage();
    secrets = MockAuthStorage();
    store = InMemorySourceStore();
  });

  Future<ProviderContainer> listening(ProviderContainer c) async {
    await c.read(sourceRecordsProvider.future);
    final sub = c.listen(loginControllerProvider, (_, __) {});
    addTearDown(sub.close);
    return c;
  }

  test('a claim pairing saves an account and writes no legacy key', () async {
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));

    await c.read(loginControllerProvider.notifier).pairWithClaimCode('ABC123');

    final state = c.read(loginControllerProvider);
    expect(state.error, isNull);
    expect(state.success, isTrue);
    expect(state.addedSource, const SourceId('minst-2:owner:inst-2'));
    expect(await secrets.read('source/minst-2/account_token'), isNotNull);
    expect(authStorage.keys, isEmpty);
    expect(await authStorage.read('auth_token'), isNull);
    expect(await authStorage.read('pairing_access_token'), isNull);
  });

  test('a QR pairing saves an account and writes no legacy key', () async {
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));

    await c.read(loginControllerProvider.notifier).pairWithQrCode(
          const QrPairingData(
            instanceId: 'inst-2',
            nodeAddr: '{"id":"node-abc","addrs":[]}',
            claimCode: 'ABC123',
          ),
        );

    final state = c.read(loginControllerProvider);
    expect(state.error, isNull);
    expect(state.addedSource, const SourceId('minst-2:owner:inst-2'));
    expect(authStorage.keys, isEmpty);
  });

  test('every server added reports its own source, the first included',
      () async {
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));
    final controller = c.read(loginControllerProvider.notifier);

    await controller.pairWithClaimCode('ABC123');
    expect(c.read(loginControllerProvider).addedSource,
        const SourceId('minst-2:owner:inst-2'));

    final second = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-3'))));
    await second
        .read(loginControllerProvider.notifier)
        .pairWithClaimCode('ABC123');
    final state = second.read(loginControllerProvider);
    expect(state.addedSource, const SourceId('minst-3:owner:inst-3'));
  });

  test('a TOTP login saves an account and writes no legacy key', () async {
    final c = await listening(containerFor(auth: _TotpAuth(authStorage)));
    final controller = c.read(loginControllerProvider.notifier);

    await controller.login('https://friend.example', 'maya', 'pw');
    expect(c.read(loginControllerProvider).totpChallenge, isNotNull);
    expect(c.read(loginControllerProvider).success, isFalse);

    await controller.submitTotpCode('123456');

    final state = c.read(loginControllerProvider);
    expect(state.error, isNull);
    expect(state.success, isTrue);
    expect(state.totpChallenge, isNull);
    expect(state.addedSource, isNotNull);
    expect((await store.load()).accounts, hasLength(1));
    expect(authStorage.keys, isEmpty);
  });

  test('the save survives the screen going away mid-pairing', () async {
    final pairing = _GatedPairing(_credentials('inst-2'));
    final c = containerFor(pairing: pairing);
    await c.read(sourceRecordsProvider.future);
    final sub = c.listen(loginControllerProvider, (_, __) {});

    final done =
        c.read(loginControllerProvider.notifier).pairWithClaimCode('ABC123');
    // The screen leaves: the only listener goes and the controller, being
    // autoDispose, would be torn down.
    sub.close();
    await Future<void>.delayed(Duration.zero);

    pairing.gate.complete();
    await done;

    final records = (await store.load()).accounts;
    expect(records.single.account.id, 'minst-2');
    expect(await secrets.read('source/minst-2/account_token'), isNotNull);
  });

  test('a re-auth for another server is refused with a message', () async {
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));

    await c
        .read(loginControllerProvider.notifier)
        .pairWithClaimCode('ABC123', reauthAccountId: 'minst-9');

    final state = c.read(loginControllerProvider);
    expect(state.error, 'That code belongs to a different server.');
    expect(state.success, isFalse);
    expect((await store.load()).accounts, isEmpty);
  });

  test('a save on storage that cannot persist warns the user', () async {
    secrets.degradedValue = true;
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));

    await c.read(loginControllerProvider.notifier).pairWithClaimCode('ABC123');

    expect(c.read(loginControllerProvider).credentialsNotPersisted, isTrue);
  });

  test(
      'a failure saving the credentials after a good login shows the save '
      'message', () async {
    store = _FailingWriteStore();
    final c = await listening(containerFor(auth: _GrantedAuth(authStorage)));

    await c.read(loginControllerProvider.notifier).login(
          'https://friend.example',
          'maya',
          'pw',
        );

    final state = c.read(loginControllerProvider);
    expect(state.success, isFalse);
    expect(state.isLoading, isFalse);
    // The save's own wording, not the login mapping's "Cannot connect".
    expect(state.error, const SourceException.unreachable().viewerMessage);
  });

  test('an unexpected stored-session outcome ends loading with an error',
      () async {
    final c =
        await listening(containerFor(auth: _LoginSuccessAuth(authStorage)));

    await c.read(loginControllerProvider.notifier).login(
          'https://friend.example',
          'maya',
          'pw',
        );

    final state = c.read(loginControllerProvider);
    expect(state.isLoading, isFalse);
    expect(state.error, isNotNull);
  });

  test('a URL login saves an account from the granted token', () async {
    final server = ScriptedMydiaTransport.responses([
      {
        '__typename': 'RootMutationType',
        'login': {
          '__typename': 'LoginPayload',
          'token': 'tok',
          'user': {
            '__typename': 'User',
            'id': 'u1',
            'username': 'maya',
            'email': null,
            'displayName': null,
          },
          'expiresIn': 100,
          'totpRequired': false,
          'challengeToken': null,
        },
      },
    ]);
    final auth = AuthService(
      storage: authStorage,
      deviceInfo: _FakeDeviceInfo(),
      transportFactory: (_) => server,
    );
    final c = await listening(containerFor(auth: auth));

    await c.read(loginControllerProvider.notifier).login(
          'https://friend.example/',
          'maya',
          'pw',
        );

    final state = c.read(loginControllerProvider);
    expect(state.success, isTrue);
    expect(state.addedSource, isNotNull);
    expect(await authStorage.read('auth_token'), isNull);
    expect(authStorage.keys, isEmpty);
  });

  group('password failures are mapped by error kind', () {
    Future<LoginState> loginFailing(Object failure) async {
      final auth = AuthService(
        storage: authStorage,
        deviceInfo: _FakeDeviceInfo(),
        transportFactory: (_) => ScriptedMydiaTransport.responses([failure]),
      );
      final c = await listening(containerFor(auth: auth));
      await c.read(loginControllerProvider.notifier).login(
            'https://friend.example',
            'maya',
            'wrong',
          );
      final state = c.read(loginControllerProvider);
      expect(state.success, isFalse);
      return state;
    }

    test('unreachable', () async {
      expect((await loginFailing(const SourceException.unreachable())).error,
          'Cannot connect to server. Check the URL and your network.');
    });

    test('not found', () async {
      expect((await loginFailing(const SourceException.notFound())).error,
          'Server not found. Check the URL.');
    });

    test('unauthorized', () async {
      expect((await loginFailing(const SourceException.unauthorized())).error,
          'Invalid username or password');
    });

    test('the server says the credentials are wrong', () async {
      expect(
          (await loginFailing(graphqlError('Invalid username or password')))
              .error,
          'Invalid username or password');
    });

    test('the server has local login turned off', () async {
      expect(
          (await loginFailing(graphqlError('Local authentication is disabled')))
              .error,
          'Local authentication is disabled');
    });

    test('any other server error', () async {
      expect((await loginFailing(graphqlError('Something broke'))).error,
          'Login failed. Please check your credentials.');
    });
  });

  group('verification code failures are mapped by error kind', () {
    Map<String, dynamic> challenge() => {
          'login': {
            '__typename': 'LoginPayload',
            'token': null,
            'user': null,
            'expiresIn': 0,
            'totpRequired': true,
            'challengeToken': 'challenge',
          },
        };

    Future<LoginState> submitFailing(Object failure) async {
      final auth = AuthService(
        storage: authStorage,
        deviceInfo: _FakeDeviceInfo(),
        transportFactory: (_) => ScriptedMydiaTransport((request, _) =>
            request.operation == 'VerifyTotp' ? failure : challenge()),
      );
      final c = await listening(containerFor(auth: auth));
      final controller = c.read(loginControllerProvider.notifier);
      await controller.login('https://friend.example', 'maya', 'pw');
      expect(c.read(loginControllerProvider).totpChallenge, isNotNull);
      await controller.submitTotpCode('123456');
      return c.read(loginControllerProvider);
    }

    test('unreachable', () async {
      expect((await submitFailing(const SourceException.unreachable())).error,
          'Cannot connect to server. Check the URL and your network.');
    });

    test('too many attempts keeps the challenge', () async {
      final state = await submitFailing(
          graphqlError('Too many login attempts. Please try again later.'));
      expect(state.error, 'Too many login attempts. Please try again later.');
      expect(state.totpChallenge, isNotNull);
    });

    test('an expired sign-in drops the challenge', () async {
      final state = await submitFailing(
          graphqlError('Sign-in expired, please try again'));
      expect(state.error, 'Sign-in expired, please try again');
      expect(state.totpChallenge, isNull);
    });

    test('a wrong code', () async {
      final state = await submitFailing(graphqlError('Invalid code'));
      expect(state.error, 'Invalid code');
      expect(state.totpChallenge, isNotNull);
    });
  });
}
