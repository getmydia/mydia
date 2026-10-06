// A server added through login opens on its own page, whichever server it is.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/device_info_service.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login/login_controller.dart';
import 'package:player/presentation/screens/login_screen.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

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
      serverUrl: 'p2p://node-$instanceId',
      deviceId: 'dev-12345678',
      mediaToken: 'media',
      accessToken: 'access',
      deviceToken: 'device',
      serverPublicKey: Uint8List(32),
      directUrls: const [],
      instanceName: 'Friends',
      instanceId: instanceId,
      serverNodeAddr: '{"id":"node-$instanceId","addrs":[]}',
    );

void main() {
  testWidgets('adding the first server lands on its own source home',
      (tester) async {
    final store = InMemorySourceStore();
    final container = ProviderContainer(overrides: [
      noDownloadsOverride,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      loginDeviceInfoProvider.overrideWithValue(_FakeDeviceInfo()),
      pairingServiceProvider
          .overrideWithValue(_FakePairing(_credentials('inst-2'))),
      authServiceProvider
          .overrideWithValue(AuthService(storage: MockAuthStorage())),
    ]);
    addTearDown(container.dispose);
    await container.read(sourceRecordsProvider.future);

    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/s/:id',
        builder: (_, state) => Text('home ${state.pathParameters['id']}'),
      ),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'ABC123');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(find.text('home minst-2:owner:inst-2'), findsOneWidget);
  });
}
