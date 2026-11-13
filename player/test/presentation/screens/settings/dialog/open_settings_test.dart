import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/connections/connections_constellation_card.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/dialog/open_settings.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/screens/sources/mydia_instance_screen.dart';

import '../../../../core/sources/mydia/mydia_account_harness.dart'
    show mydiaRecord;
import '../../../../test_utils/mock_auth_storage.dart';
import '../../../../test_utils/mydia_test_source.dart';
import '../../../../test_utils/no_downloads.dart';
import '../../../../test_utils/toast_harness.dart';
import '../../connections/connections_hub_fixtures.dart';
import '../../connections/fake_peer_sync_service.dart';

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus(
        isInitialized: true,
        isRelayConnected: false,
        connectedPeersCount: 0,
      );
}

class _FakeUpdateNotifier extends UpdateNotifier {
  @override
  UpdateState build() =>
      const UpdateState(manualCheck: ManualCheckBehaviour.checksOnly);
}

class _FakeSettingsController extends SettingsController {
  @override
  Future<UserSettings> build() async => const UserSettings(
        serverUrl: 'mydia.local:4000',
        username: 'admin',
        defaultQuality: '1080p',
      );
}

class _StubRegistration extends NodeRegistrations {
  @override
  Map<SourceId, RegistrationStatus> build() => const {};

  @override
  void retryAll() {}
}

void main() {
  final recordA = mydiaRecord('a', addedAtMs: 0);
  final recordB = mydiaRecord('b', addedAtMs: 1);
  late Box<dynamic> box;
  var boxCounter = 0;

  setUp(() async {
    resetSettingsDialogForTest();
    boxCounter += 1;
    box = await Hive.openBox<dynamic>('open_settings_$boxCounter',
        bytes: Uint8List(0));
  });
  tearDown(() async => box.close());

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool dialog,
    SettingsCategory initial = SettingsCategory.playback,
    ConnectionsOverview? overview,
  }) async {
    final peers = InMemoryPeerSyncStore();
    final peerService = FakePeerSyncService(store: peers);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = InMemorySourceStore();
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
    Widget stub(String path) => Scaffold(body: Text('at $path'));
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openSettings(context, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      for (final p in [
        '/settings',
        '/settings/diagnostics',
        '/sources/manage',
        '/sources/add',
        '/unlock',
      ])
        GoRoute(path: p, builder: (_, __) => stub(p)),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsDialogEnabledProvider.overrideWithValue(dialog),
        settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        p2pStatusNotifierProvider.overrideWith(_FakeP2pStatusNotifier.new),
        updateProvider.overrideWith(_FakeUpdateNotifier.new),
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
        remoteControlSettingsProvider
            .overrideWith((ref) async => RemoteControlSettings(box: box)),
        nodeRegistrationsProvider.overrideWith(_StubRegistration.new),
        activeSourceIdProvider.overrideWithValue(testMydiaSourceId),
        mediaSourceProvider.overrideWith((ref, id) => null),
        serverCompatibilityProvider.overrideWith((ref, id) async =>
            const ServerCompatibility(
                info: null, verdict: CompatibilityVerdict.unknown)),
        peerSyncStoreProvider.overrideWithValue(peers),
        peerSyncServiceProvider.overrideWithValue(peerService),
        peerGroupRosterProvider.overrideWithValue(PeerGroupRoster(
          store: peers,
          localNodeId: () => peerService.localNodeId,
          isPeerConnected: (_) => true,
        )),
        connectionsDirectSourceProvider.overrideWithValue(null),
        if (overview != null)
          connectionsOverviewProvider.overrideWithValue(overview),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  SettingsCategory selected(WidgetTester tester) =>
      SettingsCategory.values.singleWhere((c) => tester
          .widget<ListTile>(find.byKey(Key('settings-category-${c.name}')))
          .selected);

  /// The dialog's nav, as a row in the visible pane would find it.
  SettingsNav dialogNav(WidgetTester tester) => SettingsNavScope.of(
      tester.element(find.byKey(const Key('settings-dialog-close')).first));

  testWidgets('off desktop, openSettings follows the old routes',
      (tester) async {
    await pumpApp(tester, dialog: false, initial: SettingsCategory.connections);
    await open(tester);
    expect(find.text('at /sources/manage'), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
  });

  testWidgets('off desktop, a bare openSettings still goes to /settings',
      (tester) async {
    await pumpApp(tester, dialog: false);
    await open(tester);
    expect(find.text('at /settings'), findsOneWidget);
  });

  testWidgets('on desktop, openSettings opens the dialog on the category',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.about);
    await open(tester);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(find.byKey(const Key('check-for-updates-row')), findsOneWidget);
  });

  testWidgets('ctrl-comma opens on connections', (tester) async {
    await pumpApp(tester, dialog: true);
    final host = tester.element(find.text('open'));
    attachSettingsHost(host);
    addTearDown(() => detachSettingsHost(host));

    expect(openSettingsFromShortcut(), isTrue);
    await tester.pumpAndSettle();
    expect(selected(tester), SettingsCategory.connections);
    expect(
        find.byKey(const Key('connections-servers-section')), findsOneWidget);
  });

  testWidgets('/settings/paired-devices maps to connections', (tester) async {
    await pumpApp(tester, dialog: true);
    final context = tester.element(find.text('open'));
    expect(openSettingsForRoute(context, '/settings/paired-devices'), isTrue);
    await tester.pumpAndSettle();
    expect(selected(tester), SettingsCategory.connections);
  });

  testWidgets('a second open retargets instead of stacking', (tester) async {
    await pumpApp(tester, dialog: true);
    await open(tester);
    final context = tester.element(find.byKey(const Key('settings-dialog')));
    expect(openSettingsForRoute(context, '/settings/diagnostics'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(find.byKey(const Key('copy-diagnostics')), findsOneWidget);
  });

  testWidgets('openSettingsForRoute ignores other routes and mobile',
      (tester) async {
    await pumpApp(tester, dialog: false);
    final context = tester.element(find.text('open'));
    expect(openSettingsForRoute(context, '/settings'), isFalse);
    expect(openSettingsForRoute(context, '/downloads'), isFalse);
  });

  testWidgets('the connections pane is the hub under its wide header',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.connections);
    await open(tester);
    final card = find.byType(ConnectionsConstellationCard);
    expect(tester.widget<ConnectionsConstellationCard>(card).wide, isTrue);
    expect(find.byKey(const Key('connections-this-device')), findsNothing);
    expect(find.byKey(const Key('settings-dialog-close')), findsOneWidget);
    // The card already names the page: the pane header does not repeat it.
    expect(find.text('Servers & devices'), findsNWidgets(2),
        reason: 'once in the sidebar, once on the card');
  });

  testWidgets('openPairedDevices selects connections and scrolls to devices',
      (tester) async {
    await pumpApp(
      tester,
      dialog: true,
      overview: hubOverview(
        servers: [
          for (var i = 0; i < 6; i++) hubServer('s$i', 'Home Mydia $i'),
        ],
        devices: [hubDevice('n1', 'Pixel phone', 'android')],
      ),
    );
    await open(tester);
    expect(selected(tester), SettingsCategory.playback);

    dialogNav(tester).openPairedDevices();
    await tester.pumpAndSettle();
    expect(selected(tester), SettingsCategory.connections);
    final dialog = tester.getRect(find.byKey(const Key('settings-dialog')));
    final devices =
        tester.getRect(find.byKey(const Key('connections-devices-section')));
    expect(dialog.overlaps(devices), isTrue,
        reason: 'the devices section is scrolled into the pane');
    expect(
      devices.top,
      greaterThanOrEqualTo(dialog.top),
    );
  });

  testWidgets('paired devices is no longer pushed onto playback',
      (tester) async {
    await pumpApp(tester, dialog: true);
    await open(tester);
    dialogNav(tester).openPairedDevices();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings-category-playback')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog-back')), findsNothing);
    expect(
        SettingsDialogScope.of(
                tester.element(find.byKey(const Key('settings-dialog'))))
            .paneNavigator(SettingsCategory.playback)
            .canPop(),
        isFalse);
  });

  testWidgets('Servers opens an instance in the pane and back returns',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.connections);
    await open(tester);
    await tester
        .tap(find.byKey(Key('connections-server-${recordA.account.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mydia-instance-server')), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-dialog-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-add')), findsOneWidget);
  });

  testWidgets('Add server closes the dialog, then pushes add-a-server',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.connections);
    await open(tester);
    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
    expect(find.text('at /sources/add'), findsOneWidget);
  });

  testWidgets('the unlock screen opens above the dialog and returns to it',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.connections);
    await open(tester);
    unawaited(GoRouter.of(tester.element(find.byKey(const Key('manage-add'))))
        .push<void>('/unlock'));
    await tester.pumpAndSettle();
    expect(find.text('at /unlock'), findsOneWidget);

    GoRouter.of(tester.element(find.text('at /unlock'))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
  });

  testWidgets('removing the open instance pops back to the hub',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.connections);
    await open(tester);
    await tester
        .tap(find.byKey(Key('connections-server-${recordA.account.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mydia-instance-server')), findsNothing);
    expect(find.byKey(const Key('manage-add')), findsOneWidget);
  });

  group('routeMenuNavigation', () {
    List<String> run(String route, {required bool dialogEnabled}) {
      final went = <String>[];
      routeMenuNavigation(route, dialogEnabled: dialogEnabled, go: went.add);
      return went;
    }

    test('drops settings routes the shell cannot open on desktop', () {
      for (final route in [
        '/settings',
        '/sources/manage',
        '/settings/diagnostics',
        '/settings/paired-devices',
      ]) {
        expect(run(route, dialogEnabled: true), isEmpty, reason: route);
      }
    });

    test('routes other destinations on desktop', () {
      expect(run('/downloads', dialogEnabled: true), ['/downloads']);
    });

    test('routes settings plainly when the dialog is off', () {
      expect(run('/settings', dialogEnabled: false), ['/settings']);
    });
  });

  test('isSettingsShortcut matches Ctrl+, key-down only', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    const up = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(isSettingsShortcut(down, controlPressed: true), isTrue);
    expect(isSettingsShortcut(down, controlPressed: false), isFalse);
    expect(isSettingsShortcut(up, controlPressed: true), isFalse);
  });

  test('isSettingsShortcut rejects Shift, Alt (AltGr) and Meta', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(isSettingsShortcut(down, controlPressed: true, shiftPressed: true),
        isFalse);
    expect(isSettingsShortcut(down, controlPressed: true, altPressed: true),
        isFalse);
    expect(isSettingsShortcut(down, controlPressed: true, metaPressed: true),
        isFalse);
  });
}
