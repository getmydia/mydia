/// The hub as the desktop settings dialog hosts it: kept mounted while the
/// section it should scroll to changes, and headed by the wide constellation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/connections_constellation_card.dart';
import 'package:player/presentation/screens/connections/connections_hub.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

import '../../../test_utils/toast_harness.dart';
import 'connections_hub_fixtures.dart';
import 'fake_peer_sync_service.dart';

class _Overview extends Notifier<ConnectionsOverview> {
  _Overview(this.initial);
  final ConnectionsOverview initial;

  @override
  ConnectionsOverview build() => initial;

  void set(ConnectionsOverview next) => state = next;
}

final _overviewProvider = NotifierProvider<_Overview, ConnectionsOverview>(
    () => throw StateError('overridden in _pump'));

class _Harness {
  _Harness(this.nav, this.section, this.container);
  final RecordingNav nav;
  final ValueNotifier<String?> section;
  final ProviderContainer container;

  void setOverview(ConnectionsOverview next) =>
      container.read(_overviewProvider.notifier).set(next);
}

final _manyServers = [
  for (var i = 0; i < 6; i++) hubServer('s$i', 'Home Mydia $i'),
];
// A getter, so each test stamps its own sync time (see [hubDevice]).
List<ConnectionDevice> get _devices =>
    [hubDevice('n1', 'Pixel phone', 'android')];

Future<_Harness> _pump(
  WidgetTester tester,
  ConnectionsOverview overview, {
  bool wideHeader = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(390, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final nav = RecordingNav();
  final section = ValueNotifier<String?>(null);
  addTearDown(section.dispose);
  final store = InMemoryPeerSyncStore();
  final service =
      FakePeerSyncService(store: store, isPaired: overview.isPaired);
  final container = ProviderContainer(overrides: [
    _overviewProvider.overrideWith(() => _Overview(overview)),
    connectionsOverviewProvider
        .overrideWith((ref) => ref.watch(_overviewProvider)),
    connectionsDirectSourceProvider.overrideWithValue(null),
    peerSyncServiceProvider.overrideWithValue(service),
    peerSyncStoreProvider.overrideWithValue(store),
    peerGroupRosterProvider.overrideWithValue(PeerGroupRoster(
      store: store,
      localNodeId: () => service.localNodeId,
      isPeerConnected: (_) => true,
    )),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(
        body: SettingsNavScope(
          nav: nav,
          child: ValueListenableBuilder<String?>(
            valueListenable: section,
            builder: (_, value, __) => ConnectionsHubBody(
              initialSection: value,
              wideHeader: wideHeader,
            ),
          ),
        ),
      ),
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return _Harness(nav, section, container);
}

double _devicesTop(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(const Key('connections-devices-section'))).dy;

void main() {
  testWidgets('a section requested after mount scrolls into view',
      (tester) async {
    final h = await _pump(
        tester, hubOverview(servers: _manyServers, devices: _devices));
    expect(_devicesTop(tester), greaterThan(600));

    h.section.value = 'devices';
    await tester.pumpAndSettle();
    expect(_devicesTop(tester), inInclusiveRange(0, 600));
  });

  testWidgets('a repeated request scrolls again after the user scrolls away',
      (tester) async {
    final h = await _pump(
        tester, hubOverview(servers: _manyServers, devices: _devices));
    h.section.value = 'devices';
    await tester.pumpAndSettle();
    h.section.value = null;
    await tester.pumpAndSettle();

    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(_devicesTop(tester), greaterThan(600));

    h.section.value = 'devices';
    await tester.pumpAndSettle();
    expect(_devicesTop(tester), inInclusiveRange(0, 600));
  });

  testWidgets('scrolls again once the servers finish loading', (tester) async {
    final h = await _pump(
      tester,
      hubOverview(serversLoading: true, devices: _devices),
      settle: false,
    );
    h.section.value = 'devices';
    // The loading spinner never settles, so pump the scroll out by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The servers arrive and push the devices back down.
    h.setOverview(hubOverview(servers: _manyServers, devices: _devices));
    await tester.pumpAndSettle();
    expect(_devicesTop(tester), inInclusiveRange(0, 600));
  });

  testWidgets('a failed read falls back to the This device card as heading',
      (tester) async {
    await _pump(
      tester,
      hubOverview(serversFailed: true, devices: _devices),
      wideHeader: true,
    );
    expect(find.byType(ConnectionsConstellationCard), findsNothing);
    expect(find.byKey(const Key('connections-this-device')), findsOneWidget);
  });

  testWidgets('the wide header is neither tappable nor focusable',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    final h = await _pump(
      tester,
      hubOverview(servers: _manyServers, devices: _devices),
      wideHeader: true,
    );
    tester.view.physicalSize = const Size(900, 1400);
    await tester.pumpAndSettle();

    final card = find.byType(ConnectionsConstellationCard);
    expect(card, findsOneWidget);
    expect(tester.widget<ConnectionsConstellationCard>(card).wide, isTrue);

    await tester.tap(card, warnIfMissed: false);
    await tester.pump();
    expect(h.nav.calls, isEmpty);

    final focusable = find.descendant(
      of: card,
      matching: find
          .byWidgetPredicate((w) => w is Focus && w.canRequestFocus != false),
    );
    expect(focusable, findsNothing);
    expect(find.descendant(of: card, matching: find.byType(InkWell)),
        findsNothing);
    expect(
        find.descendant(of: card, matching: find.byIcon(Icons.chevron_right)),
        findsNothing);
  });
}
