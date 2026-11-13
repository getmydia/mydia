import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/account_detail_page.dart';
import 'package:player/presentation/screens/connections/connections_hub.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';
import 'connections_hub_fixtures.dart';
import 'fake_peer_sync_service.dart';

/// Built per test, never cached: [hubDevice] stamps its sync time from the
/// wall clock, and CI runs the whole suite in one isolate, where a value
/// first read while tests are declared is minutes old once this one runs.
ConnectionsOverview _populated() => hubOverview(
      servers: [
        hubServer('home', 'Home Mydia',
            host: 'home.example.net', inAllServers: true),
        hubServer('plex-acc', 'Basement Plex', kind: SourceKind.plex),
      ],
      devices: [
        hubDevice('n1', 'Pixel phone', 'android'),
        hubDevice('n2', 'NAS', 'linux'),
      ],
    );

/// Opens the real account detail page, as the router and the dialog do.
class _PushingNav extends RecordingNav {
  _PushingNav(this.navigatorKey);
  final GlobalKey<NavigatorState> navigatorKey;
  @override
  void openAccount(String accountId) {
    super.openAccount(accountId);
    navigatorKey.currentState?.push(MaterialPageRoute<void>(
        builder: (_) => AccountDetailPage(accountId: accountId)));
  }
}

class _Harness {
  _Harness(this.nav, this.service);
  final RecordingNav nav;
  final FakePeerSyncService service;
}

Future<_Harness> _pump(
  WidgetTester tester,
  ConnectionsOverview overview, {
  String? initialSection,
  SourceId? direct,
  bool settle = true,
}) async {
  final nav = RecordingNav();
  final store = InMemoryPeerSyncStore();
  final service =
      FakePeerSyncService(store: store, isPaired: overview.isPaired);
  final roster = PeerGroupRoster(
    store: store,
    localNodeId: () => service.localNodeId,
    isPeerConnected: (_) => true,
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      connectionsOverviewProvider.overrideWithValue(overview),
      connectionsDirectSourceProvider.overrideWithValue(direct),
      peerSyncServiceProvider.overrideWithValue(service),
      peerSyncStoreProvider.overrideWithValue(store),
      peerGroupRosterProvider.overrideWithValue(roster),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: SettingsNavScope(
        nav: nav,
        child: ConnectionsHubScreen(initialSection: initialSection),
      ),
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return _Harness(nav, service);
}

void _phone(WidgetTester tester, {double height = 600}) {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('renders sections', (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, _populated());

    expect(find.byKey(const Key('connections-this-device')), findsOneWidget);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Reaching 2 of 2 servers · synced 5 minutes ago'),
        findsOneWidget);
    expect(
        find.byKey(const Key('connections-servers-section')), findsOneWidget);
    expect(find.byKey(const Key('connections-server-home')), findsOneWidget);
    expect(
        find.byKey(const Key('connections-server-plex-acc')), findsOneWidget);
    expect(find.text('Mydia · home.example.net'), findsOneWidget);
    expect(find.text('Plex · 1 server'), findsOneWidget);
    expect(find.byKey(const Key('manage-add')), findsOneWidget);
    expect(
        find.byKey(const Key('connections-devices-section')), findsOneWidget);
    expect(find.byKey(const Key('connections-device-n1')), findsOneWidget);
    expect(find.byKey(const Key('connections-device-n2')), findsOneWidget);
    expect(find.text('Watch progress syncs between these'), findsOneWidget);
    expect(find.byKey(const Key('connections-pair-cta')), findsOneWidget);
  });

  testWidgets('every server tap, Mydia included, opens its account',
      (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated());

    await tester.tap(find.byKey(const Key('connections-server-home')));
    await tester.pump();
    expect(h.nav.calls, ['account home']);

    await tester.tap(find.byKey(const Key('connections-server-plex-acc')));
    await tester.pump();
    expect(h.nav.calls.last, 'account plex-acc');

    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pump();
    expect(h.nav.calls.last, 'add');
  });

  testWidgets('a Mydia account\'s lock control is reachable from the hub',
      (tester) async {
    _phone(tester, height: 1400);
    final server = hubServer('home', 'Home Mydia');
    final sources = InMemorySourceStore();
    await sources.putAccount(server.record);
    final navigatorKey = GlobalKey<NavigatorState>();
    final nav = _PushingNav(navigatorKey);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => sources),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
        connectionsOverviewProvider
            .overrideWithValue(hubOverview(servers: [server])),
        connectionsDirectSourceProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => SettingsNavScope(
            nav: nav, child: toastLayerBuilder(context, child)),
        home: const ConnectionsHubScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('connections-server-home')));
    await tester.pumpAndSettle();

    expect(find.byType(AccountDetailPage), findsOneWidget);
    expect(find.byKey(const Key('manage-lock-srv')), findsOneWidget);
    expect(find.byKey(const Key('manage-settings-home')), findsOneWidget);
  });

  testWidgets('this device and device cards word their meta as one phrase',
      (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester,
        hubOverview(devices: [hubDevice('n1', 'Pixel phone', 'android')]));
    // No servers: the synced half stands alone and starts the sentence.
    expect(find.text('Synced 5 minutes ago'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('connections-device-n1')),
            matching: find.textContaining(' · synced 5 minutes ago')),
        findsOneWidget);
  });

  testWidgets('chips reflect status', (tester) async {
    _phone(tester, height: 1400);
    await _pump(
      tester,
      hubOverview(servers: [
        hubServer('a', 'Home Mydia', inAllServers: true),
        hubServer('b', 'Basement Plex',
            kind: SourceKind.plex, status: ConnectionStatus.offline),
        hubServer('c', 'NAS',
            kind: SourceKind.jellyfin, status: ConnectionStatus.needsSignIn),
        hubServer('d', 'Stash box', kind: SourceKind.stash, locked: true),
      ]),
    );

    Finder chip(String server, String text) => find.descendant(
        of: find.byKey(Key('connections-server-$server')),
        matching: find.text(text));

    expect(chip('a', 'Online'), findsOneWidget);
    expect(chip('a', 'In All servers'), findsOneWidget);
    expect(chip('b', 'Offline'), findsOneWidget);
    expect(chip('c', 'Sign in again'), findsOneWidget);
    expect(chip('d', 'Locked'), findsOneWidget);
    expect(chip('d', 'In All servers'), findsNothing);
  });

  testWidgets('direct p2p replaces online on the reached Mydia',
      (tester) async {
    _phone(tester, height: 1400);
    final server = hubServer('a', 'Home Mydia');
    await _pump(
      tester,
      hubOverview(servers: [server]),
      direct: mydiaSourceIdOf(server.record),
    );
    expect(find.text('Direct connection'), findsOneWidget);
    expect(find.text('Online'), findsNothing);
  });

  testWidgets('direct p2p shows on a Mydia reached through a non-owner profile',
      (tester) async {
    _phone(tester, height: 1400);
    final server = hubServer('a', 'Home Mydia', kidProfile: true);
    final kid = server.record.sources.singleWhere((s) => !s.profile.isOwner);
    await _pump(tester, hubOverview(servers: [server]), direct: kid.id);
    expect(find.text('Direct connection'), findsOneWidget);
    expect(find.text('Online'), findsNothing);
  });

  testWidgets('the route has a window title bar with a back button',
      (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, _populated());
    expect(find.byType(WindowTitleBar), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(WindowTitleBar),
            matching: find.text('Servers & devices')),
        findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('pair buttons open the sheet in the right mode', (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, _populated());

    await tester.tap(find.byKey(const Key('connections-enter-code')));
    await tester.pumpAndSettle();
    final input = find.descendant(
      of: find.byKey(const Key('pair-code-input')),
      matching: find.byType(EditableText),
    );
    expect(input, findsOneWidget);
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
  });

  testWidgets('show code opens the sheet with an offer', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated());

    await tester.tap(find.byKey(const Key('connections-show-code')));
    await tester.pumpAndSettle();
    expect(h.service.startOfferCount, 1);
    expect(find.byKey(const Key('pair-active-code')), findsOneWidget);
  });

  testWidgets('sync now and leave group only when paired', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated());

    await tester.tap(find.byKey(const Key('paired-sync-now-button')));
    await tester.pump();
    expect(h.service.syncAllCount, 1);

    await tester.tap(find.byKey(const Key('paired-leave-group-button')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('paired-leave-group-confirm-button')));
    await tester.pumpAndSettle();
    expect(h.service.leaveGroupCount, 1);
  });

  testWidgets('no sync footer when not paired', (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, hubOverview(servers: [hubServer('a', 'Home Mydia')]));
    expect(find.byKey(const Key('paired-sync-now-button')), findsNothing);
    expect(find.byKey(const Key('paired-leave-group-button')), findsNothing);
  });

  testWidgets('remove device revokes the peer', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated());

    await tester.tap(find.byKey(const Key('connections-device-menu-n1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-peer-n1')));
    await tester.pumpAndSettle();
    expect(h.service.revokePeerCalls, ['n1']);
  });

  testWidgets('initialSection devices scrolls the devices section into view',
      (tester) async {
    _phone(tester);
    await _pump(
      tester,
      hubOverview(
        servers: [
          for (var i = 0; i < 6; i++) hubServer('s$i', 'Home Mydia $i'),
        ],
        devices: [hubDevice('n1', 'Pixel phone', 'android')],
      ),
      initialSection: 'devices',
    );

    final top =
        tester.getTopLeft(find.byKey(const Key('connections-devices-section')));
    expect(top.dy, greaterThanOrEqualTo(0));
    expect(top.dy, lessThan(600));
  });

  testWidgets(
      'empty hub shows the add-server ghost and the pair call to action',
      (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, hubOverview());

    expect(
        find.byKey(const Key('connections-add-server-ghost')), findsOneWidget);
    expect(find.text('Add a server'), findsOneWidget);
    expect(find.byKey(const Key('connections-pair-cta')), findsOneWidget);
    expect(find.text('Sync another Mydia Player'), findsOneWidget);
    expect(find.byKey(const Key('connections-devices-section')), findsNothing);

    await tester.tap(find.byKey(const Key('connections-add-server-ghost')));
    await tester.pump();
    expect(h.nav.calls, ['add']);
  });

  testWidgets('loading servers shows a progress indicator, not the ghost',
      (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, hubOverview(serversLoading: true), settle: false);
    expect(
        find.byKey(const Key('connections-servers-loading')), findsOneWidget);
    expect(find.text('Add a server'), findsNothing);
  });

  testWidgets('a failed server read says so instead of inviting an add',
      (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, hubOverview(serversFailed: true));
    expect(find.byKey(const Key('connections-servers-failed')), findsOneWidget);
    expect(find.text('Could not read the saved servers.'), findsOneWidget);
    expect(find.byKey(const Key('connections-add-server-ghost')), findsNothing);
    expect(
        find.descendant(
          of: find.byKey(const Key('connections-servers-section')),
          matching: find.byKey(const Key('show-hidden-sources')),
        ),
        findsOneWidget);
  });

  // Builders, not overviews: this list is evaluated while tests are declared.
  for (final (name, overview) in <(String, ConnectionsOverview Function())>[
    ('empty', hubOverview),
    ('loading', () => hubOverview(serversLoading: true)),
    ('failed', () => hubOverview(serversFailed: true)),
    ('populated', _populated),
  ]) {
    testWidgets('the servers section ends with show hidden servers ($name)',
        (tester) async {
      _phone(tester, height: 1400);
      await _pump(tester, overview(), settle: false);
      final row = find.descendant(
        of: find.byKey(const Key('connections-servers-section')),
        matching: find.byKey(const Key('show-hidden-sources')),
      );
      expect(row, findsOneWidget);
      expect(find.text('Show hidden servers'), findsOneWidget);
    });
  }
}
