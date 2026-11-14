import 'dart:async';
import 'dart:convert';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_secret.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/relay/claim_resolve_result.dart';
import 'package:player/core/relay/relay_api_client.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/mock_auth_storage.dart';

class FakePeerSyncNetwork {
  final Map<String, FakePeerSyncTransport> _nodes = {};
  final Set<String> _disconnectedNodes = {};

  /// Requesters whose replies are lost on the way back: the responder handles
  /// the request, the requester sees a failure.
  final Set<String> dropRepliesTo = {};

  /// The next reply to this requester is held back until [heldReply] runs.
  String? holdNextReplyTo;
  void Function()? heldReply;
  final Map<String, int> _dialCount = {};
  int _requestIdCounter = 0;

  void register(FakePeerSyncTransport transport) {
    _nodes[transport.nodeId!] = transport;
  }

  void disconnect(String nodeId) {
    _disconnectedNodes.add(nodeId);
  }

  void reconnect(String nodeId) {
    _disconnectedNodes.remove(nodeId);
  }

  bool isConnected(String nodeId) =>
      _nodes.containsKey(nodeId) && !_disconnectedNodes.contains(nodeId);

  int dialCount(String nodeId) => _dialCount[nodeId] ?? 0;

  void resetStats(String nodeId) {
    _dialCount[nodeId] = 0;
  }

  Future<void> dial(String fromNodeId, String endpointAddrJson) async {
    final decoded = jsonDecode(endpointAddrJson) as Map<String, dynamic>;
    final targetNodeId = decoded['id'] as String;
    _dialCount[targetNodeId] = (_dialCount[targetNodeId] ?? 0) + 1;
    if (_disconnectedNodes.contains(fromNodeId) ||
        _disconnectedNodes.contains(targetNodeId) ||
        !_nodes.containsKey(targetNodeId)) {
      throw Exception('Dial failed: peer $targetNodeId is unreachable');
    }
  }

  Future<FlutterPeerSyncResponse> sendPeerSync(
    String fromNodeId,
    String toNodeId,
    FlutterPeerSyncRequest req,
  ) async {
    _dialCount[toNodeId] = (_dialCount[toNodeId] ?? 0) + 1;
    if (_disconnectedNodes.contains(fromNodeId) ||
        _disconnectedNodes.contains(toNodeId) ||
        !_nodes.containsKey(toNodeId)) {
      throw Exception('Network unreachable: failed to send to $toNodeId');
    }

    final targetTransport = _nodes[toNodeId]!;
    final reqId = 'req-${++_requestIdCounter}';
    final completer = Completer<FlutterPeerSyncResponse>();
    targetTransport._pendingResponses[reqId] = completer;
    targetTransport._requesterOf[reqId] = fromNodeId;

    targetTransport._inboundController.add(
      FlutterInboundPeerSyncRequest(
        peer: fromNodeId,
        requestId: reqId,
        request: req,
      ),
    );

    return completer.future;
  }
}

class FakePeerSyncTransport implements PeerSyncTransport {
  FakePeerSyncTransport({
    required this.network,
    required this.localNodeId,
  }) {
    network.register(this);
  }

  final FakePeerSyncNetwork network;
  final String localNodeId;
  final _inboundController =
      StreamController<FlutterInboundPeerSyncRequest>.broadcast();
  final _peerConnectedController = StreamController<String>.broadcast();
  final Map<String, Completer<FlutterPeerSyncResponse>> _pendingResponses = {};
  final Map<String, String> _requesterOf = {};
  final Set<String> addressHints = {};

  @override
  String? get nodeId => localNodeId;

  @override
  String? get nodeAddr =>
      jsonEncode({'id': localNodeId, 'addrs': <Map<String, dynamic>>[]});

  @override
  Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest =>
      _inboundController.stream;

  @override
  Stream<String> get onPeerConnected => _peerConnectedController.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> getNodeAddr() async => nodeAddr;

  @override
  Future<void> dial(String endpointAddrJson) async {
    await network.dial(localNodeId, endpointAddrJson);
  }

  @override
  Future<void> addAddressHint(String endpointAddrJson) async {
    addressHints.add(endpointAddrJson);
  }

  @override
  Future<FlutterPeerSyncResponse> sendPeerSync(
    String peer,
    FlutterPeerSyncRequest req,
  ) {
    return network.sendPeerSync(localNodeId, peer, req);
  }

  @override
  Future<void> respondToPeerSync(
    String requestId,
    FlutterPeerSyncResponse res,
  ) async {
    final completer = _pendingResponses.remove(requestId);
    final requester = _requesterOf.remove(requestId);
    if (requester != null && network.dropRepliesTo.contains(requester)) {
      completer?.completeError(Exception('reply lost'));
      return;
    }
    if (requester != null && network.holdNextReplyTo == requester) {
      network.holdNextReplyTo = null;
      network.heldReply = () => completer?.complete(res);
      return;
    }
    completer?.complete(res);
  }

  @override
  bool isConnectedToPeer(String peer) {
    return network.isConnected(peer);
  }

  void dispose() {
    _inboundController.close();
    _peerConnectedController.close();
  }
}

class FakeRelayClient extends RelayApiClient {
  final Map<String, ({String nodeAddr, String instanceId, String lookupKey})>
      _claimsByCode = {};
  final Map<String, String> _codeByLookupKey = {};
  bool failPublish = false;

  @override
  Future<({String lookupKey, String sealed})> publishClaimCode({
    required String code,
    required String nodeAddr,
    required String instanceId,
  }) async {
    if (failPublish) throw Exception('relay unavailable');
    final lookupKey = 'lookup-$code';
    _claimsByCode[code] = (
      nodeAddr: nodeAddr,
      instanceId: instanceId,
      lookupKey: lookupKey,
    );
    _codeByLookupKey[lookupKey] = code;
    return (lookupKey: lookupKey, sealed: 'sealed-$code');
  }

  @override
  Future<void> deleteClaimCode(String lookupKey) async {
    final code = _codeByLookupKey.remove(lookupKey);
    if (code != null) {
      _claimsByCode.remove(code);
    }
  }

  @override
  Future<ClaimResolveResult> resolveClaimCode(String code) async {
    final claim = _claimsByCode[code];
    if (claim == null) {
      throw ServerNotOnlineException('Claim code not found: $code');
    }
    return ClaimResolveResult(
      nodeAddr: claim.nodeAddr,
      instanceId: claim.instanceId,
    );
  }
}

class TestClock {
  DateTime now = DateTime.fromMillisecondsSinceEpoch(1000);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
  void setMs(int ms) => now = DateTime.fromMillisecondsSinceEpoch(ms);
}

class TestNode {
  TestNode({
    required this.name,
    required this.nodeId,
    required this.network,
    required this.relayClient,
    required this.clock,
  })  : store = InMemoryPeerSyncStore(),
        authStorage = MockAuthStorage() {
    transport = FakePeerSyncTransport(
      network: network,
      localNodeId: nodeId,
    );
    service = PeerSyncService(
      store: store,
      authStorage: authStorage,
      transport: transport,
      relayClient: relayClient,
      deviceName: name,
      platform: 'linux',
      resolveDeviceName: () async => name,
      clock: clock.call,
      onRemoteChangesApplied: (watchKeys, pinKeys) async {
        appliedWatchKeys.addAll(watchKeys);
        appliedPinKeys.addAll(pinKeys);
      },
    );
  }

  final String name;
  final String nodeId;
  final FakePeerSyncNetwork network;
  final FakeRelayClient relayClient;
  final TestClock clock;
  final InMemoryPeerSyncStore store;
  final MockAuthStorage authStorage;
  late final FakePeerSyncTransport transport;
  late final PeerSyncService service;
  final Set<String> appliedWatchKeys = {};
  final Set<String> appliedPinKeys = {};

  Future<void> start() => service.start();

  void dispose() {
    service.dispose();
    transport.dispose();
  }
}

void main() {
  late FakePeerSyncNetwork network;
  late FakeRelayClient relayClient;
  late TestClock clock;
  late TestNode nodeA;
  late TestNode nodeB;
  late TestNode nodeC;

  setUp(() async {
    network = FakePeerSyncNetwork();
    relayClient = FakeRelayClient();
    clock = TestClock();

    nodeA = TestNode(
      name: 'Device A',
      nodeId: 'node-a',
      network: network,
      relayClient: relayClient,
      clock: clock,
    );
    nodeB = TestNode(
      name: 'Device B',
      nodeId: 'node-b',
      network: network,
      relayClient: relayClient,
      clock: clock,
    );
    nodeC = TestNode(
      name: 'Device C',
      nodeId: 'node-c',
      network: network,
      relayClient: relayClient,
      clock: clock,
    );

    await nodeA.start();
    await nodeB.start();
    await nodeC.start();
  });

  tearDown(() {
    nodeA.dispose();
    nodeB.dispose();
    nodeC.dispose();
  });

  test('pairs_two_devices_via_claim_code_and_merges_initial_state', () async {
    // Fictional movie and episode IDs
    const movieKey = 'tmdb:movie:99901';
    const epKey = 'tmdb:ep:99902:1:1';

    // Device A has movie watched locally
    await nodeA.store.setWatched(movieKey, true, nowMs: 1000);
    // Device B has episode in progress locally
    nodeA.clock.setMs(1000);
    await nodeB.store.recordProgress(
      epKey,
      positionSeconds: 500,
      durationSeconds: 1000,
      watchedFraction: 0.5,
      nowMs: 1000,
    );

    expect(nodeA.service.isPaired, isFalse);
    expect(nodeB.service.isPaired, isFalse);

    // Device A starts pairing offer
    final offer = await nodeA.service.startPairingOffer();
    expect(offer.code.length, 6);
    expect(nodeA.service.activeOffer, isNotNull);

    // Device B pairs with code
    await nodeB.service.pairWithCode(offer.code);

    // Both devices share the same groupId and are paired
    expect(nodeA.service.isPaired, isTrue);
    expect(nodeB.service.isPaired, isTrue);
    expect(nodeA.service.groupId, isNotNull);
    expect(nodeB.service.groupId, equals(nodeA.service.groupId));

    // Both list each other in store.members()
    expect(nodeA.store.member('node-b'), isNotNull);
    expect(nodeA.store.member('node-b')!.revoked, isFalse);
    expect(nodeB.store.member('node-a'), isNotNull);
    expect(nodeB.store.member('node-a')!.revoked, isFalse);

    // Both hold both watch records
    expect(nodeA.store.watchRecord(movieKey)?.watched, isTrue);
    expect(nodeA.store.watchRecord(epKey)?.positionSeconds, 500);

    expect(nodeB.store.watchRecord(movieKey)?.watched, isTrue);
    expect(nodeB.store.watchRecord(epKey)?.positionSeconds, 500);
  });

  test('expires_active_code_after_five_wrong_guesses', () async {
    final offer = await nodeA.service.startPairingOffer();
    final validCode = offer.code;

    // Send 5 wrong pair requests from node B directly
    for (var i = 0; i < 5; i++) {
      final res = await nodeB.transport.sendPeerSync(
        'node-a',
        FlutterPeerSyncRequest.pair(
          claimCode: 'WRONG$i',
          deviceName: 'Attacker',
          platform: 'linux',
        ),
      );
      expect(res, isA<FlutterPeerSyncResponse_PairRejected>());
    }

    // After 5 wrong attempts, the offer should be expired/discarded
    expect(nodeA.service.activeOffer, isNull);

    // The 6th attempt with the originally valid code must also be rejected
    final res6 = await nodeB.transport.sendPeerSync(
      'node-a',
      FlutterPeerSyncRequest.pair(
        claimCode: validCode,
        deviceName: 'Device B',
        platform: 'linux',
      ),
    );
    expect(res6, isA<FlutterPeerSyncResponse_PairRejected>());
  });

  test('three_peer_offline_transitive_convergence', () async {
    const movieKey = 'tmdb:movie:99901';

    // Pair A <-> B
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);

    // Pair B <-> C
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);

    expect(nodeA.service.groupId, equals(nodeB.service.groupId));
    expect(nodeB.service.groupId, equals(nodeC.service.groupId));

    // Disconnect A from the network
    network.disconnect('node-a');

    // At t = 1000, A marks movie watched locally
    clock.setMs(1000);
    await nodeA.store.setWatched(movieKey, true, nowMs: 1000);

    // At t = 2000, B and C run syncAll()
    clock.setMs(2000);
    await nodeB.service.syncAll();
    await nodeC.service.syncAll();

    // At t = 3000, reconnect A; A syncs with B (while C is disconnected)
    clock.setMs(3000);
    network.reconnect('node-a');
    network.disconnect('node-c');
    await nodeA.service.syncAll();

    // At t = 4000, disconnect A, reconnect C, and run B.syncAll()
    clock.setMs(4000);
    network.disconnect('node-a');
    network.reconnect('node-c');
    // B already tried C while passing on A's change at t = 3000, when C was
    // unreachable, so C is in its cooldown.
    await nodeB.service.syncAll(ignoreCooldown: true);

    // Verify C now has movie watched with updatedAt == 1000
    final recordC = nodeC.store.watchRecord(movieKey);
    expect(recordC, isNotNull);
    expect(recordC!.watched, isTrue);
    expect(recordC.updatedAt, 1000);
  });

  test('revocation_propagates_and_blocks_peer', () async {
    const movieKey = 'tmdb:movie:99903';

    // Pair A <-> B, B <-> C
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);

    // C calls revokePeer(nodeA) and syncs with B
    clock.setMs(2000);
    await nodeC.service.revokePeer('node-a');
    await nodeC.service.syncAll();
    await nodeB.service.syncAll();

    // Verify B marks A as revoked: true
    expect(nodeB.store.member('node-a')?.revoked, isTrue);

    // When A sends Sync to B, B replies NotAuthorized and ignores A's records
    clock.setMs(3000);
    await nodeA.store.setWatched(movieKey, true, nowMs: 3000);
    final secretA = PeerGroupSecret.fromBase64Url(
      (await nodeA.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    final syncReq = FlutterPeerSyncRequest.sync_(
      authProof: secretA.authProof('node-a'),
      roster: nodeA.store.members().values.map((m) => m.toWire()).toList(),
      sinceLandedMs: PlatformInt64Util.from(0),
      watchRecords: [nodeA.store.watchRecord(movieKey)!.toWire()],
      pinRecords: const [],
    );

    final res = await nodeA.transport.sendPeerSync('node-b', syncReq);
    expect(res, isA<FlutterPeerSyncResponse_NotAuthorized>());

    // B has ignored A's records
    expect(nodeB.store.watchRecord(movieKey), isNull);
  });

  test('authorizes_and_active_member_ids_follow_proof_roster_and_group',
      () async {
    expect(nodeB.service.activeMemberIds(), isEmpty);
    expect(nodeB.service.authorizes('node-a', 'anything'), isFalse);

    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);

    final secret = PeerGroupSecret.fromBase64Url(
      (await nodeB.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    expect(nodeB.service.activeMemberIds(), ['node-a', 'node-c']);
    expect(
        nodeB.service.authorizes('node-a', secret.authProof('node-a')), isTrue);
    // A proof is bound to its sender.
    expect(nodeB.service.authorizes('node-a', secret.authProof('node-c')),
        isFalse);
    // The secret alone does not admit a node the roster never held.
    expect(nodeB.service.authorizes('node-x', secret.authProof('node-x')),
        isFalse);

    clock.setMs(2000);
    await nodeB.service.revokePeer('node-a');
    expect(nodeB.service.authorizes('node-a', secret.authProof('node-a')),
        isFalse);
    expect(nodeB.service.activeMemberIds(), ['node-c']);

    await nodeB.service.leaveGroup();
    expect(nodeB.service.activeMemberIds(), isEmpty);
    expect(nodeB.service.authorizes('node-c', secret.authProof('node-c')),
        isFalse);
  });

  test('auth_proof_for_self_is_the_proof_members_accept', () async {
    expect(nodeB.service.authProofForSelf(), isNull);

    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);

    final proof = nodeB.service.authProofForSelf();
    expect(proof, isNotNull);
    expect(nodeA.service.authorizes('node-b', proof!), isTrue);
    expect(nodeB.service.member('node-a')?.nodeId, 'node-a');
    expect(nodeB.service.member('NODE-A')?.nodeId, 'node-a');
    expect(nodeB.service.member('node-x'), isNull);

    await nodeB.service.leaveGroup();
    expect(nodeB.service.authProofForSelf(), isNull);
  });

  test('unreachable_peer_enters_60s_cooldown_until_cleared', () async {
    // Pair A <-> B
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    // Disconnect B so dialing B fails
    network.disconnect('node-b');
    network.resetStats('node-b');

    // First mutation triggers dial to B, which fails and enters 60s cooldown
    clock.setMs(1000);
    await nodeA.service.notifyLocalMutation();
    expect(network.dialCount('node-b'), 1);

    // Second mutation within 60s (at t = 1000 + 30s) does not dial B again
    clock.advance(const Duration(seconds: 30));
    await nodeA.service.notifyLocalMutation();
    expect(network.dialCount('node-b'), 1);

    // Advancing past 60s (at t = 1000 + 61s) dials B again
    clock.advance(const Duration(seconds: 31));
    await nodeA.service.notifyLocalMutation();
    expect(network.dialCount('node-b'), 2);

    // syncAll(ignoreCooldown: true) dials B even inside cooldown
    await nodeA.service.syncAll(ignoreCooldown: true);
    expect(network.dialCount('node-b'), 3);
  });

  test('leave_group_revokes_self_clears_secret_and_keeps_local_watch_records',
      () async {
    const movieKey = 'tmdb:movie:99901';
    await nodeA.store.setWatched(movieKey, true, nowMs: 1000);

    // Pair A <-> B
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    expect(nodeA.service.isPaired, isTrue);

    // A leaves group
    await nodeA.service.leaveGroup();

    // B sees A as revoked: true
    expect(nodeB.store.member('node-a')?.revoked, isTrue);

    // Deletes peer_group/secret on A
    expect(await nodeA.authStorage.read(PeerGroupSecret.storageKey), isNull);
    expect(nodeA.service.isPaired, isFalse);
    expect(nodeA.service.groupId, isNull);

    // Clears A's roster
    expect(nodeA.store.members(), isEmpty);

    // Leaves A's watchRecords intact
    expect(nodeA.store.watchRecord(movieKey)?.watched, isTrue);
  });

  test('pairs_two_devices_via_qr_code', () async {
    const movieKey = 'tmdb:movie:99901';
    await nodeA.store.setWatched(movieKey, true, nowMs: 1000);

    final offer = await nodeA.service.startPairingOffer();
    expect(offer.qrJson, isNotEmpty);

    await nodeB.service.pairWithQr(offer.qrJson);

    expect(nodeA.service.isPaired, isTrue);
    expect(nodeB.service.isPaired, isTrue);
    expect(nodeB.service.groupId, equals(nodeA.service.groupId));
    expect(nodeB.store.watchRecord(movieKey)?.watched, isTrue);
  });

  test('cancels_active_pairing_offer_clears_active_offer_and_relay', () async {
    final offer = await nodeA.service.startPairingOffer();
    expect(nodeA.service.activeOffer, isNotNull);

    await nodeA.service.cancelPairingOffer();
    expect(nodeA.service.activeOffer, isNull);

    // Attempting to pair with cancelled code from node B fails
    expect(
      () => nodeB.service.pairWithCode(offer.code),
      throwsA(isA<ServerNotOnlineException>()),
    );
  });

  test('notifies_remote_changes_applied_for_watch_and_pin_records', () async {
    const movieKey = 'tmdb:movie:99901';
    const pinKey = 'pin:m:harbor-of-echoes-2024';

    // Pair A <-> B
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    // Add watch record and pin record on A
    clock.setMs(2000);
    await nodeA.store.setWatched(movieKey, true, nowMs: 2000);
    await nodeA.store.setPin(
      groupKey: 'harbor-of-echoes-2024',
      isShow: false,
      tmdbId: 99901,
      pinned: true,
      nowMs: 2000,
    );

    nodeB.appliedWatchKeys.clear();
    nodeB.appliedPinKeys.clear();

    // A syncs with B
    await nodeA.service.syncAll();

    expect(nodeB.appliedWatchKeys, contains(movieKey));
    expect(nodeB.appliedPinKeys, contains(pinKey));
  });

  test('revoked_peer_cannot_unrevoke_itself_and_inbound_request_is_rejected',
      () async {
    // Pair A <-> B
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);

    // B revokes A
    clock.setMs(2000);
    await nodeB.service.revokePeer('node-a');
    expect(nodeB.store.member('node-a')?.revoked, isTrue);

    // A tries to send a sync request with candidate roster claiming revoked: false with higher clock
    clock.setMs(5000);
    final secretA = PeerGroupSecret.fromBase64Url(
      (await nodeA.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    const unrevokeAttempt = PeerMember(
      nodeId: 'node-a',
      deviceName: 'Device A',
      platform: 'linux',
      updatedAt: 5000,
      revoked: false,
    );
    final syncReq = FlutterPeerSyncRequest.sync_(
      authProof: secretA.authProof('node-a'),
      roster: [unrevokeAttempt.toWire()],
      sinceLandedMs: PlatformInt64Util.from(0),
      watchRecords: const [],
      pinRecords: const [],
    );

    final res = await nodeA.transport.sendPeerSync('node-b', syncReq);
    expect(res, isA<FlutterPeerSyncResponse_NotAuthorized>());

    // B still has A marked as revoked, not un-revoked
    expect(nodeB.store.member('node-a')?.revoked, isTrue);
  });

  test('handle_sync_request_does_not_advance_last_sent_landed_at_watermark',
      () async {
    const movieKey = 'tmdb:movie:99901';

    // Pair A <-> B
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    // B sets a watch record
    clock.setMs(2000);
    await nodeB.store.setWatched(movieKey, true, nowMs: 2000);

    // Initially B's watermark for A has lastSentLandedAt = 0
    expect(nodeB.store.watermark('node-a')?.lastSentLandedAt ?? 0, 0);

    // A sends a sync request to B with sinceLandedMs = 0
    final secretA = PeerGroupSecret.fromBase64Url(
      (await nodeA.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    final syncReq = FlutterPeerSyncRequest.sync_(
      authProof: secretA.authProof('node-a'),
      roster: nodeA.store.members().values.map((m) => m.toWire()).toList(),
      sinceLandedMs: PlatformInt64Util.from(0),
      watchRecords: const [],
      pinRecords: const [],
    );

    final res = await nodeA.transport.sendPeerSync('node-b', syncReq);
    expect(res, isA<FlutterPeerSyncResponse_SyncAck>());
    final ack = res as FlutterPeerSyncResponse_SyncAck;
    expect(ack.watchRecords.map((w) => w.key), contains(movieKey));

    // B does not know the reply arrived, so it does not mark the record sent:
    // only B's own next request, answered by A, moves that cursor.
    expect(nodeB.store.watermark('node-a')?.lastSentLandedAt ?? 0, 0);
  });

  test('lost_sync_reply_is_delivered_when_the_responder_next_initiates',
      () async {
    const movieKey = 'tmdb:movie:99901';
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    clock.setMs(2000);
    await nodeB.store.setWatched(movieKey, true, nowMs: 2000);

    // A asks B for what is new, and B's reply never reaches A.
    network.dropRepliesTo.add('node-a');
    await nodeA.service.syncAll(ignoreCooldown: true);
    expect(nodeA.store.watchRecord(movieKey), isNull);
    network.dropRepliesTo.clear();

    // B initiating next must still carry the record to A.
    clock.setMs(3000);
    await nodeB.service.syncAll(ignoreCooldown: true);
    expect(nodeA.store.watchRecord(movieKey)?.watched, isTrue);
  });

  Future<FlutterPeerSyncResponse> sendManualSync(
    TestNode from,
    String to, {
    List<PeerMember> roster = const [],
    List<FlutterWireWatchRecord> watch = const [],
    int since = 0,
  }) async {
    final secret = PeerGroupSecret.fromBase64Url(
      (await from.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    return from.transport.sendPeerSync(
      to,
      FlutterPeerSyncRequest.sync_(
        authProof: secret.authProof(from.nodeId),
        roster: roster.map((m) => m.toWire()).toList(),
        sinceLandedMs: PlatformInt64Util.from(since),
        watchRecords: watch,
        pinRecords: const [],
      ),
    );
  }

  test('revoked_device_cannot_enroll_a_new_node_id_with_the_group_secret',
      () async {
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);
    clock.setMs(2000);
    await nodeA.service.revokePeer('node-b');

    // B keeps the group secret. It syncs again as a node A has never seen.
    final newNode = FakePeerSyncTransport(
      network: network,
      localNodeId: 'node-b-new',
    );
    addTearDown(newNode.dispose);
    final secret = PeerGroupSecret.fromBase64Url(
      (await nodeB.authStorage.read(PeerGroupSecret.storageKey))!,
    );
    final res = await newNode.sendPeerSync(
      'node-a',
      FlutterPeerSyncRequest.sync_(
        authProof: secret.authProof('node-b-new'),
        roster: [
          const PeerMember(
            nodeId: 'node-b-new',
            deviceName: 'Device B',
            platform: 'linux',
            updatedAt: 3000,
          ).toWire(),
        ],
        sinceLandedMs: PlatformInt64Util.from(0),
        watchRecords: const [],
        pinRecords: const [],
      ),
    );

    expect(res, isA<FlutterPeerSyncResponse_NotAuthorized>());
    expect(nodeA.store.member('node-b-new'), isNull);
  });

  test('re_enrolled_device_is_accepted_again_by_the_rest_of_the_group',
      () async {
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);

    // C removes A, and B hears of it.
    clock.setMs(2000);
    await nodeC.service.revokePeer('node-a');
    await nodeB.service.syncAll(ignoreCooldown: true);
    expect(nodeB.store.member('node-a')?.revoked, isTrue);

    // A pairs with B again, on purpose.
    clock.setMs(3000);
    final again = await nodeB.service.startPairingOffer();
    await nodeA.service.pairWithCode(again.code);
    await pumpEventQueue();

    expect(nodeB.store.member('node-a')?.revoked, isFalse);
    expect(nodeC.store.member('node-a')?.revoked, isFalse);
  });

  test('revocation_wins_over_a_member_record_stamped_ahead_of_the_clock',
      () async {
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    clock.setMs(2000);
    final b = nodeA.store.member('node-b')!;
    await nodeA.store.putMember(b.copyWith(updatedAt: 9000000));
    await nodeA.service.revokePeer('node-b');

    expect(nodeA.store.member('node-b')?.revoked, isTrue);
  });

  test('leaving_revokes_this_device_even_when_its_record_is_ahead_of_the_clock',
      () async {
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    clock.setMs(2000);
    final a = nodeA.store.member('node-a')!;
    await nodeA.store.putMember(a.copyWith(updatedAt: 40000));
    await nodeA.service.leaveGroup();

    expect(nodeB.store.member('node-a')?.revoked, isTrue);
    expect(nodeA.service.groupId, isNull);
    expect(nodeA.store.members(), isEmpty);
  });

  test('late_sync_reply_does_not_restore_the_roster_after_leaving', () async {
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    // A sync is under way, its reply held back.
    network.holdNextReplyTo = 'node-a';
    final inFlight = nodeA.service.syncAll(ignoreCooldown: true);
    await pumpEventQueue();
    expect(network.heldReply, isNotNull);

    await nodeA.service.leaveGroup();
    expect(nodeA.store.members(), isEmpty);

    // The reply lands after A has left.
    network.heldReply!();
    await inFlight;
    await pumpEventQueue();

    expect(nodeA.store.members(), isEmpty);
    expect(nodeA.service.isPaired, isFalse);
  });

  test('accepted_change_is_passed_on_to_the_rest_of_the_group', () async {
    const movieKey = 'tmdb:movie:99920';
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);
    await pumpEventQueue();

    // A reaches B alone, as when A skips C during a cooldown.
    clock.setMs(2000);
    await nodeA.store.setWatched(movieKey, true, nowMs: 2000);
    final res = await sendManualSync(
      nodeA,
      'node-b',
      watch: [nodeA.store.watchRecord(movieKey)!.toWire()],
    );
    expect(res, isA<FlutterPeerSyncResponse_SyncAck>());
    await pumpEventQueue();

    expect(nodeC.store.watchRecord(movieKey)?.watched, isTrue);
  });

  test('sync_returns_the_newer_local_record_when_the_incoming_one_is_older',
      () async {
    const movieKey = 'tmdb:movie:99921';
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    clock.setMs(5000);
    await nodeB.store.setWatched(movieKey, true, nowMs: 5000);
    const stale = 3000;
    final older = FlutterWireWatchRecord(
      key: movieKey,
      watched: false,
      updatedAtMs: PlatformInt64Util.from(stale),
    );

    // The sender's cursor is past B's record, so only the winner rule can
    // bring it back.
    final res = await sendManualSync(
      nodeA,
      'node-b',
      watch: [older],
      since: 9000000,
    ) as FlutterPeerSyncResponse_SyncAck;

    expect(res.watchRecords.map((w) => w.key), contains(movieKey));
    expect(
      res.watchRecords.firstWhere((w) => w.key == movieKey).updatedAtMs.toInt(),
      5000,
    );
    expect(nodeB.store.watchRecord(movieKey)!.watched, isTrue);
  });

  test('qr_offer_is_active_without_relay_publication', () async {
    relayClient.failPublish = true;
    final offer = await nodeA.service.startPairingOffer();

    expect(offer.publishedToRelay, isFalse);
    expect(nodeA.service.activeOffer, isNotNull);

    await nodeB.service.pairWithQr(offer.qrJson);
    expect(nodeB.service.isPaired, isTrue);

    await nodeA.service.cancelPairingOffer();
    expect(nodeA.service.activeOffer, isNull);
  });

  test('paired_device_syncs_after_start_without_a_local_change', () async {
    const movieKey = 'tmdb:movie:99922';
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);

    clock.setMs(2000);
    await nodeB.store.setWatched(movieKey, true, nowMs: 2000);
    expect(nodeA.store.watchRecord(movieKey), isNull);

    // B restarts: nothing was mutated and no refresh event fires.
    await nodeB.service.start();
    await pumpEventQueue();

    expect(nodeA.store.watchRecord(movieKey)?.watched, isTrue);
  });

  test('roster_change_from_sync_notifies_listeners', () async {
    final offerA = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offerA.code);
    final offerB = await nodeB.service.startPairingOffer();
    await nodeC.service.pairWithCode(offerB.code);
    await pumpEventQueue();

    var changes = 0;
    nodeA.service.onStateChanged.listen((_) => changes++);
    await nodeA.store.clearRoster();
    await nodeA.store.putMember(nodeB.store.member('node-b')!);
    await nodeA.service.syncAll(ignoreCooldown: true);
    await pumpEventQueue();

    expect(changes, greaterThan(0));
  });

  test('a_sync_with_nothing_new_still_notifies_its_new_watermark', () async {
    final offer = await nodeA.service.startPairingOffer();
    await nodeB.service.pairWithCode(offer.code);
    await nodeA.service.syncAll(ignoreCooldown: true);
    await pumpEventQueue();

    // Nothing changes but the time: "synced X ago" must still move.
    clock.setMs(5000);
    var changes = 0;
    nodeA.service.onStateChanged.listen((_) => changes++);
    await nodeA.service.syncAll(ignoreCooldown: true);
    await pumpEventQueue();

    expect(nodeA.store.watermark('node-b')?.lastSyncedAt, 5000);
    expect(changes, greaterThan(0));
  });

  test('resolves_device_name_asynchronously_and_updates_local_member',
      () async {
    final standaloneStore = InMemoryPeerSyncStore();
    final standaloneAuth = MockAuthStorage();
    final standaloneTransport = FakePeerSyncTransport(
      network: network,
      localNodeId: 'node-standalone',
    );

    // Seed existing local member with old device name
    await standaloneStore.putMember(const PeerMember(
      nodeId: 'node-standalone',
      deviceName: 'Old Device Name',
      platform: 'linux',
      updatedAt: 1000,
    ));

    final service = PeerSyncService(
      store: standaloneStore,
      authStorage: standaloneAuth,
      transport: standaloneTransport,
      relayClient: relayClient,
      deviceName: 'Mydia Player',
      platform: 'linux',
      resolveDeviceName: () async => 'Echo Deck Pro',
      clock: clock.call,
    );

    await service.start();

    expect(service.deviceName, 'Echo Deck Pro');
    expect(
      standaloneStore.member('node-standalone')?.deviceName,
      'Echo Deck Pro',
    );

    service.dispose();
    standaloneTransport.dispose();
  });
}
