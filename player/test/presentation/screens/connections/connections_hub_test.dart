import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/connections_hub.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_peer_sync_service.dart';

class _RecordingNav implements SettingsNav {
  final calls = <String>[];
  @override
  void openInstance(SourceId id) => calls.add('instance ${id.value}');
  @override
  void openDiagnostics() => calls.add('diagnostics');
  @override
  void openPairedDevices() => calls.add('paired-devices');
  @override
  void openConnections() => calls.add('connections');
  @override
  void openAccount(String accountId) => calls.add('account $accountId');
  @override
  void accountRemoved() => calls.add('account-removed');
  @override
  void instanceRemoved() => calls.add('removed');
  @override
  void addServer() => calls.add('add');
  @override
  void reauth(SourceKind kind, String accountId) =>
      calls.add('reauth ${kind.name} $accountId');
  @override
  void switchedTo(SourceId id) => calls.add('switched ${id.value}');
}

SourceAccountRecord _record(String id, String name, SourceKind kind) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: kind,
        displayName: name,
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'o', isOwner: true),
      ],
      servers: [
        SourceServer(
          id: 'srv',
          accountId: id,
          profileId: 'owner',
          name: name,
          presence: true,
        ),
      ],
      addedAtMs: 0,
    );

ConnectionServer _server(
  String id,
  String name, {
  SourceKind kind = SourceKind.mydia,
  ConnectionStatus status = ConnectionStatus.online,
  String? host,
  bool locked = false,
  bool inAllServers = false,
}) =>
    ConnectionServer(
      record: _record(id, name, kind),
      kind: kind,
      name: name,
      host: host,
      serverCount: 1,
      status: status,
      locked: locked,
      inAllServers: inAllServers,
    );

ConnectionDevice _device(String id, String name, String platform) =>
    ConnectionDevice(
      nodeId: id,
      name: name,
      platform: platform,
      lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );

ConnectionsOverview _overview({
  List<ConnectionServer> servers = const [],
  List<ConnectionDevice> devices = const [],
  bool? isPaired,
  bool serversLoading = false,
}) =>
    ConnectionsOverview(
      localName: 'Living room TV',
      localPlatform: 'linux',
      servers: servers,
      devices: devices,
      isPaired: isPaired ?? devices.isNotEmpty,
      serversFailed: false,
      serversLoading: serversLoading,
    );

final _populated = _overview(
  servers: [
    _server('home', 'Home Mydia', host: 'home.example.net', inAllServers: true),
    _server('plex-acc', 'Basement Plex', kind: SourceKind.plex),
  ],
  devices: [
    _device('n1', 'Pixel phone', 'android'),
    _device('n2', 'NAS', 'linux'),
  ],
);

class _Harness {
  _Harness(this.nav, this.service);
  final _RecordingNav nav;
  final FakePeerSyncService service;
}

Future<_Harness> _pump(
  WidgetTester tester,
  ConnectionsOverview overview, {
  String? initialSection,
  SourceId? direct,
  bool settle = true,
}) async {
  final nav = _RecordingNav();
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
    await _pump(tester, _populated);

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

  testWidgets('mydia tap opens instance, others open account', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated);

    await tester.tap(find.byKey(const Key('connections-server-home')));
    await tester.pump();
    final mydia = _populated.servers.first.record;
    expect(h.nav.calls, ['instance ${mydiaSourceIdOf(mydia).value}']);

    await tester.tap(find.byKey(const Key('connections-server-plex-acc')));
    await tester.pump();
    expect(h.nav.calls.last, 'account plex-acc');

    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pump();
    expect(h.nav.calls.last, 'add');
  });

  testWidgets('chips reflect status', (tester) async {
    _phone(tester, height: 1400);
    await _pump(
      tester,
      _overview(servers: [
        _server('a', 'Home Mydia', inAllServers: true),
        _server('b', 'Basement Plex',
            kind: SourceKind.plex, status: ConnectionStatus.offline),
        _server('c', 'NAS',
            kind: SourceKind.jellyfin, status: ConnectionStatus.needsSignIn),
        _server('d', 'Stash box', kind: SourceKind.stash, locked: true),
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
    final server = _server('a', 'Home Mydia');
    await _pump(
      tester,
      _overview(servers: [server]),
      direct: mydiaSourceIdOf(server.record),
    );
    expect(find.text('Direct connection'), findsOneWidget);
    expect(find.text('Online'), findsNothing);
  });

  testWidgets('pair buttons open the sheet in the right mode', (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, _populated);

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
    final h = await _pump(tester, _populated);

    await tester.tap(find.byKey(const Key('connections-show-code')));
    await tester.pumpAndSettle();
    expect(h.service.startOfferCount, 1);
    expect(find.byKey(const Key('pair-active-code')), findsOneWidget);
  });

  testWidgets('sync now and leave group only when paired', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated);

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
    await _pump(tester, _overview(servers: [_server('a', 'Home Mydia')]));
    expect(find.byKey(const Key('paired-sync-now-button')), findsNothing);
    expect(find.byKey(const Key('paired-leave-group-button')), findsNothing);
  });

  testWidgets('remove device revokes the peer', (tester) async {
    _phone(tester, height: 1400);
    final h = await _pump(tester, _populated);

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
      _overview(
        servers: [
          for (var i = 0; i < 6; i++) _server('s$i', 'Home Mydia $i'),
        ],
        devices: [_device('n1', 'Pixel phone', 'android')],
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
    final h = await _pump(tester, _overview());

    expect(
        find.byKey(const Key('connections-add-server-ghost')), findsOneWidget);
    expect(find.text('Add a server'), findsOneWidget);
    expect(find.byKey(const Key('connections-pair-cta')), findsOneWidget);
    expect(find.text('Pair another device'), findsOneWidget);
    expect(find.byKey(const Key('connections-devices-section')), findsNothing);

    await tester.tap(find.byKey(const Key('connections-add-server-ghost')));
    await tester.pump();
    expect(h.nav.calls, ['add']);
  });

  testWidgets('loading servers shows a progress indicator, not the ghost',
      (tester) async {
    _phone(tester, height: 1400);
    await _pump(tester, _overview(serversLoading: true), settle: false);
    expect(
        find.byKey(const Key('connections-servers-loading')), findsOneWidget);
    expect(find.text('Add a server'), findsNothing);
  });
}
