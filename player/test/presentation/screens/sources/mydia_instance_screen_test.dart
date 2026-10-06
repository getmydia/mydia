import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_roster.dart' show DeviceRoster;
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/models/remote_device.dart';
import 'package:player/presentation/screens/sources/mydia_instance_screen.dart';

import '../../../core/sources/mydia/bound_mydia_harness.dart' show mydiaRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';
import 'fake_media_source.dart';

class _Targets extends FakeMediaSource implements RemoteTargets {
  _Targets(SourceId id) : super(id: id);

  final revoked = <String>[];

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.remoteTargets};

  @override
  Future<List<RemoteDevice>> devices() async => [
        RemoteDevice(
          id: 'd1',
          deviceName: 'Hall Screen',
          platform: 'linux',
          lastSeenAt: DateTime.utc(2026, 8, 20),
          isRevoked: false,
          createdAt: DateTime.utc(2026, 8, 1),
        ),
      ];

  @override
  Future<bool> revokeDevice(String deviceId) async {
    revoked.add(deviceId);
    return true;
  }

  @override
  DeviceRoster get roster => throw UnimplementedError();

  @override
  Future<bool> registerNode(String nodeId) async => true;
}

class _Registrations extends NodeRegistrations {
  _Registrations(this.initial);
  final Map<SourceId, RegistrationStatus> initial;
  final retried = <SourceId>[];

  @override
  Map<SourceId, RegistrationStatus> build() => initial;

  @override
  void retry(SourceId sourceId) => retried.add(sourceId);
}

class _FakeDownloads implements DownloadService {
  @override
  ({int count, int bytes}) accountDownloads(String accountId) =>
      (count: 3, bytes: 2048);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final recordA = mydiaRecord('a', addedAtMs: 0);
  final recordB = mydiaRecord('b', addedAtMs: 1);
  final idA = mydiaSourceIdOf(recordA);
  final idB = mydiaSourceIdOf(recordB);

  late InMemorySourceStore store;
  late _Targets targetsA;
  late _Registrations registrations;

  Future<void> pump(
    WidgetTester tester, {
    RegistrationStatus status = const RegistrationIdle(),
    DownloadService? downloads,
  }) async {
    store = InMemorySourceStore();
    final secrets = SourceSecrets(MockAuthStorage());
    for (final r in [recordA, recordB]) {
      await store.putAccount(r);
      await writeMydiaCredentials(
          secrets,
          r.account,
          MydiaCredentials(
            instanceId: r.servers.single.id,
            accessToken: 'tok',
            serverUrl: 'https://${r.account.id}.example.test',
          ));
    }
    targetsA = _Targets(idA);
    registrations = _Registrations({idA: status});
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        if (downloads == null)
          noDownloadsOverride
        else
          downloadManagerProvider.overrideWith((ref) async => downloads),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
        mediaSourceProvider
            .overrideWith((ref, id) => id == idA ? targetsA : null),
        nodeRegistrationsProvider.overrideWith(() => registrations),
        serverCompatibilityProvider
            .overrideWith((ref, id) async => const ServerCompatibility(
                  info: ServerCompatibilityInfo(
                    version: '1.4.0',
                    minPlayerVersion: '0.1.0',
                    recommendedPlayerVersion: '0.1.0',
                  ),
                  verdict: CompatibilityVerdict.compatible,
                )),
      ],
      child: MaterialApp.router(
        builder: toastLayerBuilder,
        routerConfig: GoRouter(
          initialLocation: '/sources/manage/x',
          routes: [
            GoRoute(
                path: '/sources/manage',
                builder: (_, __) =>
                    const Scaffold(body: Text('manage servers stub'))),
            GoRoute(
                path: '/sources/manage/x',
                builder: (_, __) => MydiaInstanceScreen(sourceId: idA)),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the four sections for this instance', (tester) async {
    await pump(tester);

    for (final key in [
      'mydia-instance-server',
      'mydia-instance-registration',
      'mydia-instance-devices',
      'mydia-instance-remove',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(find.text('Server a'), findsWidgets);
    expect(find.text('https://ma.example.test'), findsOneWidget);
    expect(find.text('v1.4.0'), findsOneWidget);
    expect(find.text('Compatible with this player'), findsOneWidget);
    expect(find.text('Hall Screen'), findsOneWidget);
  });

  testWidgets('a failed registration offers a retry for this instance only',
      (tester) async {
    await pump(tester, status: const RegistrationFailed('offline', 2, null));

    await tester
        .tap(find.byKey(const Key('mydia-instance-registration-retry')));
    await tester.pump();

    expect(registrations.retried, [idA]);
  });

  testWidgets('a registered device offers no retry', (tester) async {
    await pump(tester,
        status: RegistrationSucceeded('n' * 8, DateTime.utc(2026, 8, 1)));

    expect(find.byKey(const Key('mydia-instance-registration-retry')),
        findsNothing);
  });

  testWidgets(
      'remove asks first, says what goes with it, then removes only '
      'this instance and returns to the list', (tester) async {
    await pump(tester, downloads: _FakeDownloads());

    await tester.ensureVisible(find.byKey(const Key('mydia-instance-remove')));
    await tester.tap(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();

    expect(find.text('Remove this server from this device?'), findsOneWidget);
    expect(find.textContaining('also deletes 3 downloads'), findsOneWidget);

    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();

    expect((await store.load()).accounts.map((r) => r.account.id), ['mb']);
    expect(find.text('manage servers stub'), findsOneWidget);
    expect(idB, isNot(idA));
  });

  testWidgets('cancelling the removal keeps the instance', (tester) async {
    await pump(tester);

    await tester.ensureVisible(find.byKey(const Key('mydia-instance-remove')));
    await tester.tap(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect((await store.load()).accounts, hasLength(2));
    expect(find.byKey(const Key('mydia-instance-remove')), findsOneWidget);
  });
}
