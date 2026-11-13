import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/pair_device_sheet.dart';
import 'package:player/presentation/screens/settings/paired_devices_screen.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/screens/settings/widgets/settings_sections.dart';

import '../../../test_utils/toast_harness.dart';
import '../connections/fake_peer_sync_service.dart';

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

Widget _wrapScreen({
  required FakePeerSyncService service,
  required PeerSyncStore store,
  required PeerGroupRoster roster,
  SettingsNav? nav,
  Widget? child,
}) {
  return ProviderScope(
    overrides: [
      peerSyncServiceProvider.overrideWithValue(service),
      peerSyncStoreProvider.overrideWithValue(store),
      peerGroupRosterProvider.overrideWithValue(roster),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: SettingsNavScope(
        nav: nav ?? _RecordingNav(),
        child: child ?? const PairedDevicesScreen(),
      ),
    ),
  );
}

void main() {
  testWidgets('pairing buttons open the pair device sheet in each mode',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store, isPaired: false);
    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => service.localNodeId,
      isPeerConnected: (_) => true,
    );

    await tester.pumpWidget(_wrapScreen(
      service: service,
      store: store,
      roster: roster,
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('connections-show-code')));
    await tester.pumpAndSettle();
    expect(find.byType(PairDeviceSheet), findsOneWidget);
    expect(find.byKey(const Key('pair-active-code')), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byType(PairDeviceSheet), findsNothing);

    await tester.tap(find.byKey(const Key('connections-enter-code')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pair-code-input')), findsOneWidget);
  });

  testWidgets('removing_a_peer_marks_it_revoked_and_hides_its_row',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store, isPaired: true);
    await store.putMember(const PeerMember(
      nodeId: 'peer-alpha',
      deviceName: 'Bedroom Screen',
      platform: 'android',
      updatedAt: 1000,
      revoked: false,
    ));
    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => service.localNodeId,
      isPeerConnected: (_) => true,
    );

    await tester.pumpWidget(_wrapScreen(
      service: service,
      store: store,
      roster: roster,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('paired-device-peer-alpha')), findsOneWidget);
    expect(find.text('Bedroom Screen'), findsOneWidget);

    await tester.tap(find.byKey(const Key('remove-peer-peer-alpha')));
    await tester.pumpAndSettle();

    expect(service.revokePeerCalls, contains('peer-alpha'));
    expect(find.byKey(const Key('paired-device-peer-alpha')), findsNothing);
  });

  testWidgets('leaving_group_clears_paired_state_after_confirmation',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store, isPaired: true);
    await store.putMember(const PeerMember(
      nodeId: 'peer-alpha',
      deviceName: 'Bedroom Screen',
      platform: 'android',
      updatedAt: 1000,
      revoked: false,
    ));
    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => service.localNodeId,
      isPeerConnected: (_) => true,
    );

    await tester.pumpWidget(_wrapScreen(
      service: service,
      store: store,
      roster: roster,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('paired-sync-now-button')), findsOneWidget);
    expect(find.byKey(const Key('paired-leave-group-button')), findsOneWidget);

    // Sync now
    await tester.tap(find.byKey(const Key('paired-sync-now-button')));
    await tester.pump();
    expect(service.syncAllCount, 1);

    // Leave group prompts confirmation
    await tester.tap(find.byKey(const Key('paired-leave-group-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('paired-leave-group-confirm-button')),
        findsOneWidget);
    await tester
        .tap(find.byKey(const Key('paired-leave-group-confirm-button')));
    await tester.pumpAndSettle();

    expect(service.leaveGroupCount, 1);
    expect(find.byKey(const Key('paired-leave-group-button')), findsNothing);
    expect(find.byKey(const Key('connections-show-code')), findsOneWidget);
  });

  testWidgets('settings_row_shows_paired_count_and_navigates_to_paired_devices',
      (tester) async {
    final store = InMemoryPeerSyncStore();
    final service = FakePeerSyncService(store: store, isPaired: false);
    final roster = PeerGroupRoster(
      store: store,
      localNodeId: () => service.localNodeId,
      isPeerConnected: (_) => true,
    );
    final nav = _RecordingNav();

    await tester.pumpWidget(_wrapScreen(
      service: service,
      store: store,
      roster: roster,
      nav: nav,
      child: Scaffold(
        body: Consumer(
          builder: (context, ref, _) => ListView(
            children: [
              pairedDevicesRow(context, ref),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('paired-devices-row')), findsOneWidget);
    expect(find.text('Not paired'), findsOneWidget);

    // Add 2 active peers
    await store.putMember(const PeerMember(
      nodeId: 'peer-1',
      deviceName: 'Device 1',
      platform: 'android',
      updatedAt: 1000,
    ));
    await store.putMember(const PeerMember(
      nodeId: 'peer-2',
      deviceName: 'Device 2',
      platform: 'ios',
      updatedAt: 2000,
    ));
    service.paired = true;
    service.notify();
    await tester.pumpAndSettle();

    expect(find.text('2 paired devices'), findsOneWidget);

    await tester.tap(find.byKey(const Key('paired-devices-row')));
    await tester.pump();

    expect(nav.calls, contains('paired-devices'));
  });
}
