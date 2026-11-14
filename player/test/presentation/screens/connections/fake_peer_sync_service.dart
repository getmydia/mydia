import 'dart:async';
import 'dart:convert';

import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';

class FakePeerSyncService implements PeerSyncService {
  FakePeerSyncService({
    required this.store,
    this.localNodeId = 'local-node',
    bool isPaired = false,
  }) : _isPaired = isPaired;

  final PeerSyncStore store;
  final String localNodeId;
  bool _isPaired;

  set paired(bool value) => _isPaired = value;
  ActivePairingOffer? _activeOffer;

  final _stateChangedController = StreamController<void>.broadcast();
  final _peerPairedController = StreamController<PeerMember>.broadcast();

  final List<String> pairWithCodeCalls = [];
  final List<String> pairWithQrCalls = [];
  final List<String> revokePeerCalls = [];
  int syncAllCount = 0;
  int leaveGroupCount = 0;
  int cancelOfferCount = 0;
  int startOfferCount = 0;
  bool failOffer = false;
  bool failPairing = false;

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
  bool authorizes(String peer, String proof) => false;

  @override
  List<String> activeMemberIds() => const [];

  @override
  Future<void> start() async {}

  @override
  Future<ActivePairingOffer> startPairingOffer() async {
    startOfferCount++;
    // Taken at the call, so a later caller can start an offer ungated.
    final gate = offerGate;
    if (gate != null) await gate.future;
    if (failOffer) throw StateError('offer failed');
    final offer = _offer('ABC123');
    _activeOffer = offer;
    if (supersedeOffer) _activeOffer = _offer('XYZ789');
    notify();
    return offer;
  }

  /// Holds [startPairingOffer] pending until completed.
  Completer<void>? offerGate;

  /// A newer offer replaces this call's before it returns, as when another
  /// sheet started one meanwhile.
  bool supersedeOffer = false;

  ActivePairingOffer _offer(String code) => ActivePairingOffer(
        code: code,
        qrJson: jsonEncode({
          'node_addr': '{"id":"$localNodeId"}',
          'claim_code': code,
        }),
        lookupKey: 'lookup-$code',
        expiresAt: DateTime.now().add(const Duration(minutes: 5)),
      );

  @override
  Future<void> cancelPairingOffer() async {
    cancelOfferCount++;
    _activeOffer = null;
    notify();
  }

  /// Leave the joined peer out of the roster, as when the handshake
  /// completes before its member record arrives.
  bool skipJoinedMember = false;

  /// Also fire [onPeerPaired] on the joining side, which the real service
  /// never does, to prove the sheet toasts once whichever signal arrives.
  bool emitPairedOnJoin = false;

  /// The joining side, like the real service: the roster changes and state
  /// is notified, but [onPeerPaired] fires only on the host.
  Future<void> _join(PeerMember peer) async {
    _isPaired = true;
    if (!skipJoinedMember) await store.putMember(peer);
    if (emitPairedOnJoin) _peerPairedController.add(peer);
    notify();
  }

  /// The host side: another device claimed this device's offer.
  Future<void> hostPaired(PeerMember peer) async {
    _isPaired = true;
    _activeOffer = null;
    await store.putMember(peer);
    _peerPairedController.add(peer);
    notify();
  }

  @override
  Future<void> pairWithCode(String code) async {
    pairWithCodeCalls.add(code);
    if (failPairing) throw StateError('pairing failed');
    await _join(PeerMember(
      nodeId: 'peer-device-1',
      deviceName: 'Living Room TV',
      platform: 'android',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  @override
  Future<void> pairWithQr(String qrJson) async {
    pairWithQrCalls.add(qrJson);
    if (failPairing) throw StateError('pairing failed');
    await _join(PeerMember(
      nodeId: 'peer-device-qr',
      deviceName: 'Bedroom TV',
      platform: 'ios',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
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
