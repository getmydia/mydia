import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/l10n/l10n.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:player/presentation/screens/settings/paired_devices_screen.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/screens/settings/widgets/settings_sections.dart';

import '../../../test_utils/toast_harness.dart';

class FakePeerSyncService implements PeerSyncService {
  FakePeerSyncService({
    required this.store,
    this.localNodeId = 'local-node',
    bool isPaired = false,
  }) : _isPaired = isPaired;

  final PeerSyncStore store;
  final String localNodeId;
  bool _isPaired;
  ActivePairingOffer? _activeOffer;

  final _stateChangedController = StreamController<void>.broadcast();
  final _peerPairedController = StreamController<PeerMember>.broadcast();

  final List<String> pairWithCodeCalls = [];
  final List<String> pairWithQrCalls = [];
  final List<String> revokePeerCalls = [];
  int syncAllCount = 0;
  int leaveGroupCount = 0;

  @override
  String get deviceName => 'Test Device';

  @override
  String get platform => 'linux';

  @override
  bool get isPaired => _isPaired;

  @override
  String? get groupId => _isPaired ? 'group-alpha' : null;

  @override
  ActivePairingOffer? get activeOffer => _activeOffer;

  @override
  Stream<void> get onStateChanged => _stateChangedController.stream;

  @override
  Stream<PeerMember> get onPeerPaired => _peerPairedController.stream;

  void notify() {
    _stateChangedController.add(null);
  }

  @override
  Future<void> start() async {}

  @override
  Future<ActivePairingOffer> startPairingOffer() async {
    _activeOffer = ActivePairingOffer(
      code: 'ABC123',
      qrJson: jsonEncode({
        'node_addr': '{"id":"$localNodeId"}',
        'claim_code': 'ABC123',
      }),
      lookupKey: 'lookup-123',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
    notify();
    return _activeOffer!;
  }

  @override
  Future<void> cancelPairingOffer() async {
    _activeOffer = null;
    notify();
  }

  @override
  Future<void> pairWithCode(String code) async {
    pairWithCodeCalls.add(code);
    _isPaired = true;
    final peer = PeerMember(
      nodeId: 'peer-device-1',
      deviceName: 'Living Room TV',
      platform: 'android',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await store.putMember(peer);
    _peerPairedController.add(peer);
    notify();
  }

  @override
  Future<void> pairWithQr(String qrJson) async {
    pairWithQrCalls.add(qrJson);
    _isPaired = true;
    final peer = PeerMember(
      nodeId: 'peer-device-qr',
      deviceName: 'Bedroom TV',
      platform: 'ios',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await store.putMember(peer);
    _peerPairedController.add(peer);
    notify();
  }

  @override
  Future<void> syncAll({
    bool ignoreCooldown = false,
    String? exceptPeer,
  }) async {
    syncAllCount++;
  }

  @override
  Future<void> revokePeer(String nodeId) async {
    revokePeerCalls.add(nodeId);
    final existing = store.member(nodeId);
    if (existing != null) {
      await store.putMember(existing.copyWith(revoked: true));
    }
    final active = store.members().values.where(
          (m) => !m.revoked && m.nodeId != localNodeId,
        );
    if (active.isEmpty) {
      _isPaired = false;
    }
    notify();
  }

  @override
  Future<void> leaveGroup() async {
    leaveGroupCount++;
    _isPaired = false;
    _activeOffer = null;
    await store.clearRoster();
    notify();
  }

  @override
  Future<void> notifyLocalMutation({bool throttle = false}) async {}

  @override
  void dispose() {
    _stateChangedController.close();
    _peerPairedController.close();
  }
}

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
  testWidgets('shows_empty_state_and_generates_six_char_pairing_code',
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

    expect(find.byKey(const Key('pair-show-code-button')), findsOneWidget);
    expect(find.byKey(const Key('pair-code-input')), findsOneWidget);
    expect(find.byKey(const Key('pair-submit-code-button')), findsOneWidget);
    expect(find.byKey(const Key('pair-scan-qr-button')), findsOneWidget);

    // Initial state: no active offer
    expect(find.byKey(const Key('pair-active-code')), findsNothing);

    // Tap Show Code
    await tester.tap(find.byKey(const Key('pair-show-code-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-active-code')), findsOneWidget);
    expect(find.text('ABC-123'), findsOneWidget);
    expect(find.byKey(const Key('pair-active-qr')), findsOneWidget);
    // The QR encodes the offer's own payload (address and claim code), not a
    // placeholder: another device scanning it can pair from it alone.
    final qr = tester.widget<PairingQrCode>(
      find.byKey(const Key('pair-active-qr-image')),
    );
    expect(qr.data, service.activeOffer!.qrJson);
    expect(
      find.descendant(
        of: find.byKey(const Key('pair-active-qr-image')),
        matching: find.byType(QrImageView),
      ),
      findsOneWidget,
    );
    expect(
      jsonDecode(qr.data),
      containsPair('claim_code', 'ABC123'),
    );
    expect(find.byKey(const Key('pair-cancel-offer-button')), findsOneWidget);

    // Cancel offer
    await tester.tap(find.byKey(const Key('pair-cancel-offer-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pair-active-code')), findsNothing);
    expect(find.byKey(const Key('pair-show-code-button')), findsOneWidget);
  });

  testWidgets('hides_scan_button_where_the_scanner_is_unsupported',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
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

      expect(find.byKey(const Key('pair-scan-qr-button')), findsNothing);
      // Typing the code still works.
      expect(find.byKey(const Key('pair-code-input')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('submitting_claim_code_pairs_and_lists_peer_device',
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

    await tester.enterText(find.byKey(const Key('pair-code-input')), 'ABC-123');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pair-submit-code-button')));
    await tester.pumpAndSettle();

    expect(service.pairWithCodeCalls, contains('ABC123'));
    expect(
        find.byKey(const Key('paired-device-peer-device-1')), findsOneWidget);
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(find.byKey(const Key('remove-peer-peer-device-1')), findsOneWidget);
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
    expect(find.byKey(const Key('pair-show-code-button')), findsOneWidget);
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
    service._isPaired = true;
    service.notify();
    await tester.pumpAndSettle();

    expect(find.text('2 paired devices'), findsOneWidget);

    await tester.tap(find.byKey(const Key('paired-devices-row')));
    await tester.pump();

    expect(nav.calls, contains('paired-devices'));
  });
}
