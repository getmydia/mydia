import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;

import '../../native/lib.dart';
import '../auth/auth_storage.dart';
import '../auth/device_info_service.dart';
import '../relay/relay_api_client.dart';
import '../sources/cache/source_rules.dart';
import '../sources/connection/connection_refresh_bus.dart';
import '../sources/files/files_media_source.dart';
import '../sources/files/files_providers.dart';
import 'p2p_service.dart';
import 'peer_group_roster.dart';
import 'peer_group_secret.dart';
import 'peer_sync_records.dart';
import 'peer_sync_store.dart';

export '../sources/files/files_providers.dart' show peerSyncStoreProvider;

abstract interface class PeerSyncTransport {
  String? get nodeId;
  String? get nodeAddr;
  Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest;
  Stream<String> get onPeerConnected;
  Future<void> initialize();
  Future<String?> getNodeAddr();
  Future<void> dial(String endpointAddrJson);
  Future<void> addAddressHint(String endpointAddrJson);
  Future<FlutterPeerSyncResponse> sendPeerSync(
    String peer,
    FlutterPeerSyncRequest req,
  );
  Future<void> respondToPeerSync(
    String requestId,
    FlutterPeerSyncResponse res,
  );
  bool isConnectedToPeer(String peer);
}

class P2pPeerSyncTransport implements PeerSyncTransport {
  P2pPeerSyncTransport(this._p2pService);

  final P2pService _p2pService;

  @override
  String? get nodeId => _p2pService.nodeId;

  @override
  String? get nodeAddr => _p2pService.nodeAddr;

  @override
  Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest =>
      _p2pService.onPeerSyncRequest;

  @override
  Stream<String> get onPeerConnected => _p2pService.onPeerConnected;

  @override
  Future<void> initialize() => _p2pService.initialize();

  @override
  Future<String?> getNodeAddr() => _p2pService.getNodeAddr();

  @override
  Future<void> dial(String endpointAddrJson) =>
      _p2pService.dial(endpointAddrJson);

  @override
  Future<void> addAddressHint(String endpointAddrJson) =>
      _p2pService.addAddressHint(endpointAddrJson);

  @override
  Future<FlutterPeerSyncResponse> sendPeerSync(
    String peer,
    FlutterPeerSyncRequest req,
  ) =>
      _p2pService.sendPeerSync(peer, req);

  @override
  Future<void> respondToPeerSync(
    String requestId,
    FlutterPeerSyncResponse res,
  ) =>
      _p2pService.respondToPeerSync(requestId, res);

  @override
  bool isConnectedToPeer(String peer) => _p2pService.isConnectedToPeer(peer);
}

class ActivePairingOffer {
  const ActivePairingOffer({
    required this.code,
    required this.qrJson,
    required this.lookupKey,
    required this.expiresAt,
  });

  final String code;
  final String qrJson;
  final String lookupKey;
  final DateTime expiresAt;
}

class PeerSyncService {
  PeerSyncService({
    required PeerSyncStore store,
    required AuthStorage authStorage,
    required PeerSyncTransport transport,
    required RelayApiClient relayClient,
    required String deviceName,
    required String platform,
    Future<String> Function()? resolveDeviceName,
    Future<void> Function(
      Set<String> changedWatchKeys,
      Set<String> changedPinKeys,
    )? onRemoteChangesApplied,
    void Function(PeerMember joinedPeer)? onPeerPaired,
    DateTime Function()? clock,
  })  : _store = store,
        _authStorage = authStorage,
        _transport = transport,
        _relayClient = relayClient,
        _deviceName = deviceName,
        _platform = platform,
        _resolveDeviceName = resolveDeviceName,
        _onRemoteChangesApplied = onRemoteChangesApplied,
        _onPeerPaired = onPeerPaired,
        _clock = clock ?? DateTime.now;

  final PeerSyncStore _store;
  final AuthStorage _authStorage;
  final PeerSyncTransport _transport;
  final RelayApiClient _relayClient;
  String _deviceName;
  String get deviceName => _deviceName;
  final String _platform;
  final Future<String> Function()? _resolveDeviceName;
  final Future<void> Function(
    Set<String> changedWatchKeys,
    Set<String> changedPinKeys,
  )? _onRemoteChangesApplied;
  final void Function(PeerMember joinedPeer)? _onPeerPaired;
  final DateTime Function() _clock;

  final _stateChangedController = StreamController<void>.broadcast();
  final _peerPairedController = StreamController<PeerMember>.broadcast();
  StreamSubscription<FlutterInboundPeerSyncRequest>? _inboundSub;
  StreamSubscription<String>? _peerConnectedSub;

  PeerGroupSecret? _secret;
  ActivePairingOffer? _activeOffer;
  Timer? _activeOfferTimer;
  int _failedPairAttempts = 0;
  Timer? _throttleTimer;

  final Map<String, DateTime> _peerCooldowns = {};

  static const _alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  bool get isPaired =>
      _secret != null &&
      _store.members().values.any(
            (m) =>
                !m.revoked &&
                m.nodeId.toLowerCase() !=
                    (_transport.nodeId?.toLowerCase() ?? ''),
          );

  String? get groupId => _secret?.groupId;

  ActivePairingOffer? get activeOffer => _activeOffer;

  Stream<void> get onStateChanged => _stateChangedController.stream;
  Stream<PeerMember> get onPeerPaired => _peerPairedController.stream;

  Future<void> start() async {
    final stored = await _authStorage.read(PeerGroupSecret.storageKey);
    if (stored != null) {
      try {
        _secret = PeerGroupSecret.fromBase64Url(stored);
      } catch (_) {
        _secret = null;
      }
    }

    try {
      final name = _resolveDeviceName != null
          ? await _resolveDeviceName()
          : await DeviceInfoService().getDeviceName();
      if (name.trim().isNotEmpty) {
        _deviceName = name.trim();
        final localNodeId = _transport.nodeId;
        if (localNodeId != null) {
          final existing = _store.member(localNodeId);
          if (existing != null && existing.deviceName != _deviceName) {
            await _store.putMember(
              existing.copyWith(
                deviceName: _deviceName,
                updatedAt: max(
                    _clock().millisecondsSinceEpoch, existing.updatedAt + 1),
              ),
            );
          }
        }
      }
    } catch (_) {}

    _inboundSub ??=
        _transport.onPeerSyncRequest.listen(_handleInboundPeerSyncRequest);
    _peerConnectedSub ??= _transport.onPeerConnected.listen((_) {
      unawaited(syncAll());
    });
  }

  void _notifyStateChanged() {
    if (!_stateChangedController.isClosed) {
      _stateChangedController.add(null);
    }
  }

  static String _normalizeCode(String code) =>
      code.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();

  static String _generateCode([Random? random]) {
    final r = random ?? Random.secure();
    return List.generate(6, (_) => _alphabet[r.nextInt(_alphabet.length)])
        .join();
  }

  Future<PeerGroupSecret> _ensureSecret() async {
    if (_secret != null) return _secret!;
    final stored = await _authStorage.read(PeerGroupSecret.storageKey);
    if (stored != null) {
      try {
        _secret = PeerGroupSecret.fromBase64Url(stored);
        return _secret!;
      } catch (_) {}
    }
    final generated = PeerGroupSecret.generate();
    await _authStorage.write(
        PeerGroupSecret.storageKey, generated.toBase64Url());
    _secret = generated;
    return generated;
  }

  Future<ActivePairingOffer> startPairingOffer() async {
    await _transport.initialize();
    final nodeAddr = await _transport.getNodeAddr() ?? _transport.nodeAddr;
    if (nodeAddr == null) {
      throw StateError('P2P nodeAddr is not available');
    }

    final secret = await _ensureSecret();

    final localNodeId = _transport.nodeId;
    if (localNodeId != null) {
      final existing = _store.member(localNodeId);
      if (existing == null || existing.revoked) {
        await _store.putMember(PeerMember(
          nodeId: localNodeId,
          deviceName: _deviceName,
          platform: _platform,
          endpointAddrJson: nodeAddr,
          updatedAt: _clock().millisecondsSinceEpoch,
          revoked: false,
        ));
      }
    }

    final code = _generateCode();
    final instanceId = 'peer:${secret.groupId}';
    final sealed = await _relayClient.publishClaimCode(
      code: code,
      nodeAddr: nodeAddr,
      instanceId: instanceId,
    );

    final qrJson = jsonEncode({'node_addr': nodeAddr, 'claim_code': code});
    final expiresAt = _clock().add(const Duration(minutes: 5));

    _activeOfferTimer?.cancel();
    _activeOffer = ActivePairingOffer(
      code: code,
      qrJson: qrJson,
      lookupKey: sealed.lookupKey,
      expiresAt: expiresAt,
    );
    _failedPairAttempts = 0;

    _activeOfferTimer = Timer(const Duration(minutes: 5), () {
      cancelPairingOffer();
    });

    _notifyStateChanged();
    return _activeOffer!;
  }

  Future<void> cancelPairingOffer() async {
    final offer = _activeOffer;
    if (offer == null) return;
    _activeOffer = null;
    _activeOfferTimer?.cancel();
    _activeOfferTimer = null;
    _failedPairAttempts = 0;

    try {
      await _relayClient.deleteClaimCode(offer.lookupKey);
    } catch (_) {}

    _notifyStateChanged();
  }

  Future<void> pairWithCode(String code) async {
    await _transport.initialize();
    final resolved = await _relayClient.resolveClaimCode(code);
    final nodeAddr = resolved.nodeAddr;
    final decoded = jsonDecode(nodeAddr) as Map<String, dynamic>;
    final hostNodeId = decoded['id'] as String;

    await _completePairHandshake(
      hostNodeAddr: nodeAddr,
      hostNodeId: hostNodeId,
      claimCode: code,
    );
  }

  Future<void> pairWithQr(String qrJson) async {
    await _transport.initialize();
    final decoded = jsonDecode(qrJson) as Map<String, dynamic>;
    final nodeAddr = (decoded['node_addr'] ?? decoded['nodeAddr']) as String;
    final claimCode = (decoded['claim_code'] ?? decoded['claimCode']) as String;
    final addrMap = jsonDecode(nodeAddr) as Map<String, dynamic>;
    final hostNodeId = addrMap['id'] as String;

    await _completePairHandshake(
      hostNodeAddr: nodeAddr,
      hostNodeId: hostNodeId,
      claimCode: claimCode,
    );
  }

  Future<void> _completePairHandshake({
    required String hostNodeAddr,
    required String hostNodeId,
    required String claimCode,
  }) async {
    await _transport.addAddressHint(hostNodeAddr);
    await _transport.dial(hostNodeAddr);

    final localNodeAddr = await _transport.getNodeAddr() ?? _transport.nodeAddr;
    final req = FlutterPeerSyncRequest.pair(
      claimCode: claimCode,
      deviceName: _deviceName,
      platform: _platform,
      endpointAddrJson: localNodeAddr,
    );

    final res = await _transport.sendPeerSync(hostNodeId, req);
    if (res is FlutterPeerSyncResponse_PairRejected) {
      throw Exception('Pairing rejected: ${res.reason}');
    }
    if (res is! FlutterPeerSyncResponse_Paired) {
      throw Exception('Unexpected pairing response: $res');
    }

    _secret = PeerGroupSecret.fromBase64Url(res.groupSecretBase64);
    await _authStorage.write(
      PeerGroupSecret.storageKey,
      _secret!.toBase64Url(),
    );

    final nowMs = _clock().millisecondsSinceEpoch;
    final localNodeId = _transport.nodeId;
    if (localNodeId != null) {
      await _store.putMember(PeerMember(
        nodeId: localNodeId,
        deviceName: _deviceName,
        platform: _platform,
        endpointAddrJson: localNodeAddr,
        updatedAt: nowMs,
        revoked: false,
      ));
    }

    await _store.mergeRoster(
      res.roster.map(PeerMember.fromWire),
      nowMs: nowMs,
    );

    final changes = await _store.mergeRemote(
      watchRecords: res.watchRecords,
      pinRecords: res.pinRecords,
      nowMs: nowMs,
    );

    if (changes.changedWatchKeys.isNotEmpty ||
        changes.changedPinKeys.isNotEmpty) {
      await _onRemoteChangesApplied?.call(
        changes.changedWatchKeys,
        changes.changedPinKeys,
      );
    }

    await syncAll(ignoreCooldown: true);
    _notifyStateChanged();
  }

  Future<void> _handleInboundPeerSyncRequest(
    FlutterInboundPeerSyncRequest request,
  ) async {
    final req = request.request;
    if (req is FlutterPeerSyncRequest_Pair) {
      await _handlePairRequest(request, req);
    } else if (req is FlutterPeerSyncRequest_Sync) {
      await _handleSyncRequest(request, req);
    }
  }

  Future<void> _handlePairRequest(
    FlutterInboundPeerSyncRequest request,
    FlutterPeerSyncRequest_Pair req,
  ) async {
    final now = _clock();
    if (_activeOffer == null || now.isAfter(_activeOffer!.expiresAt)) {
      await _transport.respondToPeerSync(
        request.requestId,
        const FlutterPeerSyncResponse.pairRejected(
          reason: 'No active pairing offer or offer expired',
        ),
      );
      return;
    }

    final normalizedReq = _normalizeCode(req.claimCode);
    final normalizedOffer = _normalizeCode(_activeOffer!.code);
    if (normalizedReq != normalizedOffer) {
      _failedPairAttempts++;
      if (_failedPairAttempts >= 5) {
        final offer = _activeOffer!;
        _activeOffer = null;
        _activeOfferTimer?.cancel();
        _activeOfferTimer = null;
        _failedPairAttempts = 0;
        try {
          await _relayClient.deleteClaimCode(offer.lookupKey);
        } catch (_) {}
        _notifyStateChanged();
      }
      await _transport.respondToPeerSync(
        request.requestId,
        const FlutterPeerSyncResponse.pairRejected(
          reason: 'Invalid pairing code',
        ),
      );
      return;
    }

    final offer = _activeOffer!;
    _activeOffer = null;
    _activeOfferTimer?.cancel();
    _activeOfferTimer = null;
    _failedPairAttempts = 0;
    try {
      await _relayClient.deleteClaimCode(offer.lookupKey);
    } catch (_) {}

    final nowMs = now.millisecondsSinceEpoch;
    final joinerMember = PeerMember(
      nodeId: request.peer,
      deviceName: req.deviceName,
      platform: req.platform,
      endpointAddrJson: req.endpointAddrJson,
      updatedAt: nowMs,
      revoked: false,
    );
    await _store.putMember(joinerMember);
    if (req.endpointAddrJson != null) {
      await _transport.addAddressHint(req.endpointAddrJson!);
    }

    final rosterWire = _store.members().values.map((m) => m.toWire()).toList();
    final watchWire =
        _store.allWatchRecords().values.map((w) => w.toWire()).toList();
    final pinWire =
        _store.allPinRecords().values.map((p) => p.toWire()).toList();

    await _transport.respondToPeerSync(
      request.requestId,
      FlutterPeerSyncResponse.paired(
        groupSecretBase64: _secret!.toBase64Url(),
        roster: rosterWire,
        watchRecords: watchWire,
        pinRecords: pinWire,
      ),
    );

    _onPeerPaired?.call(joinerMember);
    _peerPairedController.add(joinerMember);
    _notifyStateChanged();
  }

  Future<void> _handleSyncRequest(
    FlutterInboundPeerSyncRequest request,
    FlutterPeerSyncRequest_Sync req,
  ) async {
    if (_secret == null) {
      await _transport.respondToPeerSync(
        request.requestId,
        const FlutterPeerSyncResponse.notAuthorized(),
      );
      return;
    }

    final valid = _secret!.verifyAuthProof(
      senderNodeId: request.peer,
      proof: req.authProof,
    );
    if (!valid) {
      await _transport.respondToPeerSync(
        request.requestId,
        const FlutterPeerSyncResponse.notAuthorized(),
      );
      return;
    }

    final senderMember = _store.member(request.peer);
    if (senderMember != null && senderMember.revoked) {
      await _transport.respondToPeerSync(
        request.requestId,
        const FlutterPeerSyncResponse.notAuthorized(),
      );
      return;
    }

    final nowMs = _clock().millisecondsSinceEpoch;
    final incomingMembers = req.roster.map(PeerMember.fromWire);
    await _store.mergeRoster(incomingMembers, nowMs: nowMs);

    _peerCooldowns.remove(request.peer);

    final changes = await _store.mergeRemote(
      watchRecords: req.watchRecords,
      pinRecords: req.pinRecords,
      nowMs: nowMs,
    );

    if (req.senderEndpointAddrJson != null) {
      await _transport.addAddressHint(req.senderEndpointAddrJson!);
    }

    final incomingKeys = {
      ...req.watchRecords.map((w) => w.key),
      ...req.pinRecords.map((p) => p.key),
    };
    final outgoingWatchRecords = _store
        .watchRecordsSince(req.sinceLandedMs.toInt())
        .where((w) => !incomingKeys.contains(w.key))
        .toList();
    final outgoingPinRecords = _store
        .pinRecordsSince(req.sinceLandedMs.toInt())
        .where((p) => !incomingKeys.contains(p.key))
        .toList();
    final outgoingWatch = outgoingWatchRecords.map((w) => w.toWire()).toList();
    final outgoingPins = outgoingPinRecords.map((p) => p.toWire()).toList();

    var maxLandedAt = 0;
    for (final w in outgoingWatchRecords) {
      if (w.landedAt > maxLandedAt) maxLandedAt = w.landedAt;
    }
    for (final p in outgoingPinRecords) {
      if (p.landedAt > maxLandedAt) maxLandedAt = p.landedAt;
    }

    if (maxLandedAt > req.sinceLandedMs.toInt()) {
      final existingWatermark = _store.watermark(request.peer);
      final baseWatermark = existingWatermark ??
          PeerWatermark(
            lastSentLandedAt: 0,
            lastPeerNowMs: 0,
            lastSyncedAt: nowMs,
          );
      final updatedLastSent = max(baseWatermark.lastSentLandedAt, maxLandedAt);
      await _store.setWatermark(
        request.peer,
        baseWatermark.copyWith(
          lastSentLandedAt: updatedLastSent,
          lastSyncedAt: nowMs,
        ),
      );
    }

    await _transport.respondToPeerSync(
      request.requestId,
      FlutterPeerSyncResponse.syncAck(
        roster: _store.members().values.map((m) => m.toWire()).toList(),
        watchRecords: outgoingWatch,
        pinRecords: outgoingPins,
        peerNowMs: PlatformInt64Util.from(nowMs),
      ),
    );

    if (changes.changedWatchKeys.isNotEmpty ||
        changes.changedPinKeys.isNotEmpty) {
      await _onRemoteChangesApplied?.call(
        changes.changedWatchKeys,
        changes.changedPinKeys,
      );
    }
  }

  bool _isInCooldown(String nodeId) {
    final failedAt = _peerCooldowns[nodeId];
    if (failedAt == null) return false;
    return _clock().difference(failedAt) < const Duration(seconds: 60);
  }

  Future<void> syncAll({bool ignoreCooldown = false}) async {
    if (_secret == null) return;
    final localNodeId = _transport.nodeId?.toLowerCase();
    final members = [
      for (final m in _store.members().values)
        if (!m.revoked &&
            (localNodeId == null || m.nodeId.toLowerCase() != localNodeId))
          m,
    ];

    for (final peer in members) {
      if (!ignoreCooldown && _isInCooldown(peer.nodeId)) {
        continue;
      }
      await _syncWithPeer(peer);
    }
  }

  Future<void> _syncWithPeer(PeerMember peer) async {
    try {
      if (peer.endpointAddrJson != null) {
        await _transport.addAddressHint(peer.endpointAddrJson!);
      }

      final watermark = _store.watermark(peer.nodeId);
      final lastSentLandedAt = watermark?.lastSentLandedAt ?? 0;
      final sinceLandedMs = watermark?.lastPeerNowMs ?? 0;

      final unsentWatch = _store.watchRecordsSince(lastSentLandedAt);
      final unsentPins = _store.pinRecordsSince(lastSentLandedAt);

      var highestLandedAtSent = lastSentLandedAt;
      for (final w in unsentWatch) {
        if (w.landedAt > highestLandedAtSent) highestLandedAtSent = w.landedAt;
      }
      for (final p in unsentPins) {
        if (p.landedAt > highestLandedAtSent) highestLandedAtSent = p.landedAt;
      }

      final localNodeId = _transport.nodeId ?? '';
      final localNodeAddr =
          await _transport.getNodeAddr() ?? _transport.nodeAddr;

      final req = FlutterPeerSyncRequest.sync_(
        authProof: _secret!.authProof(localNodeId),
        senderEndpointAddrJson: localNodeAddr,
        roster: _store.members().values.map((m) => m.toWire()).toList(),
        sinceLandedMs: PlatformInt64Util.from(sinceLandedMs),
        watchRecords: unsentWatch.map((w) => w.toWire()).toList(),
        pinRecords: unsentPins.map((p) => p.toWire()).toList(),
      );

      final res = await _transport.sendPeerSync(peer.nodeId, req);

      if (res is FlutterPeerSyncResponse_SyncAck) {
        _peerCooldowns.remove(peer.nodeId);
        final nowMs = _clock().millisecondsSinceEpoch;
        await _store.mergeRoster(
          res.roster.map(PeerMember.fromWire),
          nowMs: nowMs,
        );
        final changes = await _store.mergeRemote(
          watchRecords: res.watchRecords,
          pinRecords: res.pinRecords,
          nowMs: nowMs,
        );
        await _store.setWatermark(
          peer.nodeId,
          PeerWatermark(
            lastSentLandedAt: highestLandedAtSent,
            lastPeerNowMs: res.peerNowMs.toInt(),
            lastSyncedAt: nowMs,
          ),
        );
        if (changes.changedWatchKeys.isNotEmpty ||
            changes.changedPinKeys.isNotEmpty) {
          await _onRemoteChangesApplied?.call(
            changes.changedWatchKeys,
            changes.changedPinKeys,
          );
        }
      } else if (res is FlutterPeerSyncResponse_NotAuthorized) {
        _peerCooldowns[peer.nodeId] = _clock();
      }
    } catch (_) {
      _peerCooldowns[peer.nodeId] = _clock();
    }
  }

  Future<void> notifyLocalMutation({bool throttle = false}) async {
    if (!throttle) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      await syncAll();
      return;
    }
    if (_throttleTimer != null) return;
    _throttleTimer = Timer(const Duration(milliseconds: 500), () {
      _throttleTimer = null;
      unawaited(syncAll());
    });
  }

  Future<void> revokePeer(String nodeId) async {
    final nowMs = _clock().millisecondsSinceEpoch;
    final current = _store.member(nodeId);
    final updated = (current ??
            PeerMember(
              nodeId: nodeId,
              deviceName: 'Unknown',
              platform: 'unknown',
              updatedAt: nowMs,
              revoked: true,
            ))
        .copyWith(
      revoked: true,
      updatedAt: nowMs,
    );
    await _store.putMember(updated);
    await syncAll(ignoreCooldown: true);
    _notifyStateChanged();
  }

  Future<void> leaveGroup() async {
    final localNodeId = _transport.nodeId;
    final nowMs = _clock().millisecondsSinceEpoch;
    if (localNodeId != null) {
      final current = _store.member(localNodeId);
      if (current != null) {
        await _store.putMember(current.copyWith(
          revoked: true,
          updatedAt: nowMs,
        ));
      }
    }

    try {
      await syncAll(ignoreCooldown: true).timeout(const Duration(seconds: 3));
    } catch (_) {}

    await cancelPairingOffer();
    await _authStorage.delete(PeerGroupSecret.storageKey);
    _secret = null;
    await _store.clearRoster();
    _notifyStateChanged();
  }

  void dispose() {
    _inboundSub?.cancel();
    _peerConnectedSub?.cancel();
    _activeOfferTimer?.cancel();
    _throttleTimer?.cancel();
    _stateChangedController.close();
    _peerPairedController.close();
  }
}

final peerGroupRosterProvider = Provider<PeerGroupRoster>((ref) {
  final store = ref.watch(peerSyncStoreProvider);
  final p2p = ref.watch(p2pServiceProvider);
  return PeerGroupRoster(
    store: store,
    localNodeId: () => p2p.nodeId,
    isPeerConnected: (nodeId) => p2p.isConnectedToPeer(nodeId),
  );
});

final peerSyncServiceProvider = Provider<PeerSyncService>((ref) {
  final store = ref.watch(peerSyncStoreProvider);
  final authStorage = getAuthStorage();
  final p2p = ref.watch(p2pServiceProvider);
  final transport = P2pPeerSyncTransport(p2p);
  final relay = RelayApiClient();

  final service = PeerSyncService(
    store: store,
    authStorage: authStorage,
    transport: transport,
    relayClient: relay,
    deviceName: 'Mydia Player',
    platform: DeviceInfoService().getPlatform(),
    onRemoteChangesApplied: (changedWatchKeys, changedPinKeys) async {
      final activeSources = FilesMediaSource.activeSources.toList();
      if (changedPinKeys.isNotEmpty) {
        for (final source in activeSources) {
          for (final key in changedPinKeys) {
            final pinRecord = store.allPinRecords()[key];
            if (pinRecord == null) continue;
            if (source.matcher.hasFilesForGroup(pinRecord.groupKey)) {
              if (pinRecord.pinned) {
                await source.matcher.applyRemotePin(
                  pinRecord.groupKey,
                  isShow: pinRecord.isShow,
                  tmdbId: pinRecord.tmdbId,
                );
              } else {
                final current = source.index.group(pinRecord.groupKey);
                if (current != null && current.pinned) {
                  await source.index.putGroup(current.copyWith(pinned: false));
                  await source.invalidateTargets(
                    FilesMediaSource.groupLandedTargets(source.source.id),
                  );
                }
              }
            }
          }
        }
      }
      if (changedWatchKeys.isNotEmpty) {
        for (final source in activeSources) {
          await source.invalidateTargets(
            SourceRules.watchedChanged(source.source.id),
          );
        }
      }
    },
  );

  final refreshSub = ref.watch(connectionRefreshBusProvider).events.listen((_) {
    unawaited(service.syncAll(ignoreCooldown: true));
  });

  ref.onDispose(() {
    refreshSub.cancel();
    service.dispose();
  });

  return service;
});
