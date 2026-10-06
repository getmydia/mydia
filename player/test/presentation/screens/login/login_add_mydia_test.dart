// Every login flow (claim code, URL and password, TOTP, QR) stores the result
// as a Mydia account and leaves the legacy AuthService storage alone.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/auth/device_info_service.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/connection/connection_provider.dart'
    show storedRelayUrlProvider;
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login/login_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/stub_graphql_client.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

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

class _FakeDeviceInfo extends DeviceInfoService {
  @override
  Future<String> getDeviceId() async => 'device-1';
  @override
  Future<String> getDeviceName() async => 'Test Device';
  @override
  String getPlatform() => 'linux';
}

PairingCredentials _credentials(String instanceId) => PairingCredentials(
      serverUrl: 'p2p://node-abc',
      deviceId: 'dev-12345678',
      mediaToken: 'media',
      accessToken: 'access',
      deviceToken: 'device',
      serverPublicKey: Uint8List(32),
      directUrls: const [],
      instanceName: 'Friends',
      instanceId: instanceId,
      serverNodeAddr: '{"id":"node-abc","addrs":[]}',
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
      authStateProvider.overrideWith(_Unauthenticated.new),
      noDownloadsOverride,
      storedRelayUrlProvider.overrideWith((ref) async => null),
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

  test('the first server added is the bound one, the next is not', () async {
    final c = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-2'))));
    final controller = c.read(loginControllerProvider.notifier);

    await controller.pairWithClaimCode('ABC123');
    expect(c.read(loginControllerProvider).addedIsBound, isTrue);

    final second = await listening(
        containerFor(pairing: _FakePairing(_credentials('inst-3'))));
    await second
        .read(loginControllerProvider.notifier)
        .pairWithClaimCode('ABC123');
    // Same store: inst-2 was there first, so inst-3 is not the bound one.
    final state = second.read(loginControllerProvider);
    expect(state.addedSource, const SourceId('minst-3:owner:inst-3'));
    expect(state.addedIsBound, isFalse);
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
    final link = StubLink.responses([
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
      clientFactory: (_) => stubClient(link),
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
}
