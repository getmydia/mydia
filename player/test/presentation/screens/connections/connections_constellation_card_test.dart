import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/connections/connections_constellation_card.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

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

ConnectionServer _server(String id, String name, ConnectionStatus status,
        {SourceKind kind = SourceKind.mydia}) =>
    ConnectionServer(
      record: SourceAccountRecord(
        account: ProviderAccount(
          id: id,
          kind: kind,
          displayName: name,
          storageNamespace: 'source/$id',
          activeProfileId: 'owner',
        ),
        profiles: const [],
        servers: const [],
        addedAtMs: 0,
      ),
      kind: kind,
      name: name,
      host: null,
      serverCount: 1,
      status: status,
      locked: false,
      inAllServers: true,
    );

ConnectionDevice _device(String id, String name, String platform) =>
    ConnectionDevice(
        nodeId: id, name: name, platform: platform, lastSyncedAt: null);

ConnectionsOverview _overview({
  List<ConnectionServer> servers = const [],
  List<ConnectionDevice> devices = const [],
  bool serversFailed = false,
  bool serversLoading = false,
}) =>
    ConnectionsOverview(
      localName: 'Living room TV',
      localPlatform: 'linux',
      servers: servers,
      devices: devices,
      isPaired: devices.isNotEmpty,
      serversFailed: serversFailed,
      serversLoading: serversLoading,
    );

final _populated = _overview(
  servers: [
    _server('a', 'Home Mydia', ConnectionStatus.online),
    _server('b', 'Basement Plex', ConnectionStatus.online,
        kind: SourceKind.plex),
    _server('c', 'NAS', ConnectionStatus.offline, kind: SourceKind.jellyfin),
  ],
  devices: [
    _device('p', 'Pixel phone', 'android'),
    _device('t', 'Living room TV', 'linux'),
  ],
);

Future<_RecordingNav> _pump(
    WidgetTester tester, ConnectionsOverview overview) async {
  final nav = _RecordingNav();
  await tester.pumpWidget(ProviderScope(
    overrides: [connectionsOverviewProvider.overrideWithValue(overview)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SettingsNavScope(
          nav: nav,
          child: const SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: ConnectionsConstellationCard(),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  return nav;
}

void main() {
  testWidgets('empty state shows ghost labels', (tester) async {
    await _pump(tester, _overview());
    expect(find.text('Add a server'), findsOneWidget);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(find.text('Add your other servers and sync progress across devices'),
        findsOneWidget);
  });

  testWidgets('footer counts', (tester) async {
    await _pump(tester, _populated);
    expect(find.text('2 of 3 servers online'), findsOneWidget);
    expect(find.text('Synced with 2 devices'), findsOneWidget);
    expect(find.text('Basement Plex'), findsOneWidget);
    expect(find.text('Pixel phone'), findsOneWidget);
  });

  testWidgets('the footer wraps on a narrow phone at large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await _pump(tester, _populated);

    expect(tester.takeException(), isNull);
    expect(find.text('2 of 3 servers online'), findsOneWidget);
  });

  testWidgets('semantics label summarises footer', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _populated);
    expect(
      tester.getSemantics(find.byKey(const Key('connections-card'))),
      matchesSemantics(
        label: 'Servers and devices. 2 of 3 servers online. '
            'Synced with 2 devices.',
        isButton: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('tap opens connections', (tester) async {
    final nav = await _pump(tester, _populated);
    await tester.tap(find.byKey(const Key('connections-card')));
    await tester.pump();
    expect(nav.calls, ['connections']);
  });

  testWidgets('loading records show no ghosts and no empty footer',
      (tester) async {
    await _pump(
        tester,
        _overview(
          serversLoading: true,
          devices: [_device('p', 'Pixel phone', 'android')],
        ));
    expect(find.text('Add a server'), findsNothing);
    expect(find.text('Pair a device'), findsNothing);
    expect(find.text('Add your other servers and sync progress across devices'),
        findsNothing);
    expect(find.textContaining('servers online'), findsNothing);
    expect(find.text('Living room TV'), findsOneWidget);
    expect(find.text('Pixel phone'), findsOneWidget);
    expect(find.text('Synced with 1 device'), findsOneWidget);
  });

  testWidgets('loading with no devices shows only this device', (tester) async {
    await _pump(tester, _overview(serversLoading: true));
    expect(find.text('Add a server'), findsNothing);
    expect(find.text('Pair a device'), findsNothing);
    expect(find.text('Add your other servers and sync progress across devices'),
        findsNothing);
    expect(find.text('Living room TV'), findsOneWidget);
  });

  testWidgets('records error shows fallback row', (tester) async {
    final nav = await _pump(tester, _overview(serversFailed: true));
    expect(find.byKey(const Key('connections-card-fallback')), findsOneWidget);
    expect(find.byKey(const Key('connections-card')), findsNothing);
    await tester.tap(find.byKey(const Key('connections-card-fallback')));
    await tester.pump();
    expect(nav.calls, ['connections']);
  });
}
