// A guest add runs the same pairing and login steps as home but stores the
// result as its own source, leaving home's session and pairing alone.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/auth/device_info_service.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login/login_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';
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
  late MockAuthStorage homeStorage;
  late MockAuthStorage secrets;
  late InMemorySourceStore store;

  ProviderContainer containerFor({
    PairingService? pairing,
    AuthService? auth,
  }) {
    final c = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(secrets)),
      loginDeviceInfoProvider.overrideWithValue(_FakeDeviceInfo()),
      if (pairing != null) pairingServiceProvider.overrideWithValue(pairing),
      authServiceProvider
          .overrideWithValue(auth ?? AuthService(storage: homeStorage)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  setUp(() {
    homeStorage = MockAuthStorage();
    secrets = MockAuthStorage();
    store = InMemorySourceStore();
  });

  test('a guest claim pairing saves a source and leaves home alone', () async {
    final c = containerFor(pairing: _FakePairing(_credentials('inst-2')));
    await c.read(sourceRecordsProvider.future);
    final sub = c.listen(loginControllerProvider, (_, __) {});
    addTearDown(sub.close);

    await c
        .read(loginControllerProvider.notifier)
        .pairWithClaimCode('ABC123', guest: const GuestTarget());

    final state = c.read(loginControllerProvider);
    expect(state.error, isNull);
    expect(state.success, isTrue);
    expect(state.guestSource, const SourceId('minst-2:owner:inst-2'));
    expect(await secrets.read('source/minst-2/account_token'), isNotNull);
    expect(homeStorage.keys, isEmpty);
    expect(await homeStorage.read('pairing_access_token'), isNull);
  });

  test('a guest URL login saves a source from the granted token', () async {
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
      storage: homeStorage,
      deviceInfo: _FakeDeviceInfo(),
      clientFactory: (_) => stubClient(link),
    );
    final c = containerFor(auth: auth);
    await c.read(sourceRecordsProvider.future);
    final sub = c.listen(loginControllerProvider, (_, __) {});
    addTearDown(sub.close);

    await c.read(loginControllerProvider.notifier).login(
          'https://friend.example/',
          'maya',
          'pw',
          guest: const GuestTarget(),
        );

    final state = c.read(loginControllerProvider);
    expect(state.success, isTrue);
    expect(state.guestSource, isNotNull);
    expect(await homeStorage.read('auth_token'), isNull);
    expect(homeStorage.keys, isEmpty);
  });
}
