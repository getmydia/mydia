import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/connections_hub.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../connections/fake_peer_sync_service.dart';

GoRouter _router(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        for (final path in [
          '/',
          '/settings/diagnostics',
          '/sources/manage',
          '/sources/manage/:id',
          '/sources/manage/account/:accountId',
          '/sources/add',
          '/sources/add/:kind',
          '/s/:sourceId',
        ])
          GoRoute(path: path, builder: (_, state) => Text('at ${state.uri}')),
      ],
    );

Future<GoRouter> _pump(WidgetTester tester, String initial) async {
  final router = _router(initial);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();
  return router;
}

SourceAccountRecord _plex(String id) => SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: 'Basement Plex',
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'Owner', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 's1',
            accountId: id,
            profileId: 'owner',
            name: 'Basement Plex',
            machineIdentifier: 's1'),
      ],
      addedAtMs: 1700000000000,
    );

/// The real app router, with one saved server so it does not send every
/// location to add-a-server.
Future<GoRouter> _pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final peers = InMemoryPeerSyncStore();
  final container = ProviderContainer(overrides: [
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
    authServiceProvider
        .overrideWithValue(AuthService(storage: MockAuthStorage())),
    mediaSourceProvider.overrideWith((ref, id) => null),
    connectionsOverviewProvider.overrideWithValue(const ConnectionsOverview(
      localName: 'Living room TV',
      localPlatform: 'linux',
      servers: [],
      devices: [],
      isPaired: false,
      serversFailed: false,
    )),
    connectionsDirectSourceProvider.overrideWithValue(null),
    peerSyncStoreProvider.overrideWithValue(peers),
    peerSyncServiceProvider
        .overrideWithValue(FakePeerSyncService(store: peers)),
  ]);
  addTearDown(container.dispose);
  final router = container.read(appRouterProvider);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  ));
  await container.read(sourceRecordsProvider.future);
  await container.read(sourceRecordsProvider.notifier).putAccount(_plex('p'));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('router nav pushes the same locations the screens used to', (
    tester,
  ) async {
    final router = await _pump(tester, '/');
    final nav = RouterSettingsNav(router);

    nav.openInstance(const SourceId('m1'));
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage/m1'), findsOneWidget);

    nav.openDiagnostics();
    await tester.pumpAndSettle();
    expect(find.text('at /settings/diagnostics'), findsOneWidget);

    nav.addServer();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add'), findsOneWidget);

    nav.reauth(SourceKind.plex, 'acct1');
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add/plex?account=acct1'), findsOneWidget);
  });

  testWidgets('openConnections pushes the hub', (tester) async {
    final router = await _pump(tester, '/');
    RouterSettingsNav(router).openConnections();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);
  });

  testWidgets('openPairedDevices pushes the hub with section=devices',
      (tester) async {
    final router = await _pump(tester, '/');
    RouterSettingsNav(router).openPairedDevices();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage?section=devices'), findsOneWidget);
  });

  testWidgets('paired-devices route redirects to the hub devices section',
      (tester) async {
    final router = await _pumpApp(tester);
    router.go('/settings/paired-devices');
    await tester.pumpAndSettle();

    final hub =
        tester.widget<ConnectionsHubScreen>(find.byType(ConnectionsHubScreen));
    expect(hub.initialSection, 'devices');
    expect(router.routerDelegate.currentConfiguration.uri.toString(),
        '/sources/manage?section=devices');
  });

  testWidgets('instanceRemoved returns to the list only from an instance page',
      (
    tester,
  ) async {
    final router = await _pump(tester, '/sources/manage/m1');
    RouterSettingsNav(router).instanceRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);

    router.go('/');
    await tester.pumpAndSettle();
    RouterSettingsNav(router).instanceRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /'), findsOneWidget);
  });

  testWidgets('accountRemoved pops back to the hub that pushed the account',
      (tester) async {
    final router = await _pump(tester, '/sources/manage');
    final nav = RouterSettingsNav(router)..openAccount('a1');
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage/account/a1'), findsOneWidget);

    nav.accountRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);
  });

  testWidgets('accountRemoved on a directly loaded account goes to the hub',
      (tester) async {
    final router = await _pump(tester, '/sources/manage/account/a1');
    expect(router.canPop(), isFalse);

    RouterSettingsNav(router).accountRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);
  });

  testWidgets('instanceRemoved also leaves an instance pushed from the hub',
      (tester) async {
    final router = await _pump(tester, '/sources/manage');
    final nav = RouterSettingsNav(router)..openInstance(const SourceId('m1'));
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage/m1'), findsOneWidget);

    nav.instanceRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/manage'), findsOneWidget);
  });

  testWidgets('accountRemoved stays put once the router has moved on',
      (tester) async {
    final router = await _pump(tester, '/sources/add');
    RouterSettingsNav(router).accountRemoved();
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add'), findsOneWidget);
  });

  testWidgets('of() falls back to the router without a scope', (tester) async {
    await _pump(tester, '/');
    final context = tester.element(find.text('at /'));
    expect(SettingsNavScope.of(context), isA<RouterSettingsNav>());
  });
}
