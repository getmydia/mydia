/// Fetches the files libraries the other members of this player's sync
/// group lend it, and keeps a copy of each one's index in [PeerFilesStore].
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../native/lib.dart';
import '../sources/files/files_account.dart' show kFilesLocalAccountId;
import '../sources/sources_providers.dart' show sourceRecordsProvider;
import '../sources/store/source_records.dart';
import 'p2p_service.dart';
import 'peer_files_host.dart' show filesDedupeKey, sharedFilesAccounts;
import 'peer_files_store.dart';
import 'peer_files_transport.dart';
import 'peer_sync_service.dart';

/// This device's id for the account [hostAccountId] lent by [nodeId]. Every
/// device's local folders are `flocal`, so the host's id alone would collide
/// with this device's own, and with another host's.
String peerFilesAccountId(String nodeId, String hostAccountId) {
  final hash = sha256.convert(utf8.encode(nodeId)).toString();
  return 'p${hash.substring(0, 12)}_$hostAccountId';
}

/// One account another member lends this device.
@immutable
class PeerSharedAccount {
  const PeerSharedAccount({
    required this.nodeId,
    required this.deviceName,
    required this.wire,
  });

  final String nodeId;

  /// The lending device's name, from its peer sync member record.
  final String deviceName;

  /// The account's entry in the host's last manifest this device read.
  final FlutterWireSharedAccount wire;

  String get localAccountId => peerFilesAccountId(nodeId, wire.accountId);

  @override
  bool operator ==(Object other) =>
      other is PeerSharedAccount &&
      other.nodeId == nodeId &&
      other.deviceName == deviceName &&
      other.wire == wire;

  @override
  int get hashCode => Object.hash(nodeId, deviceName, wire);
}

enum _Fetch { done, stale, failed }

/// Keeps [accounts] and the store in step with what each active member
/// lends.
///
/// Refreshes on [start], on every change to the sync group's state (which
/// includes each completed sync round), when a member connects, and on
/// [refresh]. Refreshes run one at a time; one asked for while another runs
/// waits for it and then runs once for everything asked meanwhile.
class PeerFilesClient {
  PeerFilesClient({
    required PeerFilesTransport transport,
    required PeerSyncService sync,
    required PeerFilesStore store,
    required List<SourceAccountRecord> Function() localAccounts,
    Stream<String>? peerConnected,
  })  : _transport = transport,
        _sync = sync,
        _store = store,
        _localAccounts = localAccounts,
        _peerConnected = peerConnected;

  /// How many times one member's fetch goes back to the manifest after a
  /// `StaleRevision`, before keeping the copy it has until the next refresh.
  static const maxRestarts = 2;

  final PeerFilesTransport _transport;
  final PeerSyncService _sync;
  final PeerFilesStore _store;
  final List<SourceAccountRecord> Function() _localAccounts;
  final Stream<String>? _peerConnected;

  final _accounts = ValueNotifier<List<PeerSharedAccount>>(const []);
  ValueListenable<List<PeerSharedAccount>> get accounts => _accounts;

  /// Each lent account by its local id: who lends it and its latest
  /// manifest entry. Accounts with no index yet are held here but not shown.
  final _lent = <String, ({String nodeId, FlutterWireSharedAccount wire})>{};

  StreamSubscription<void>? _stateSub;
  StreamSubscription<String>? _connectedSub;
  bool _started = false;
  bool _disposed = false;

  Future<void>? _running;
  bool _queuedAll = false;
  final _queuedNodes = <String>{};

  /// Shows what the store kept from earlier launches, then listens and
  /// refreshes.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    for (final a in _store.storedAccounts()) {
      _lent[a.localAccountId] = (nodeId: a.nodeId, wire: a.wire);
    }
    _publish();
    _stateSub = _sync.onStateChanged.listen((_) => unawaited(refresh()));
    _connectedSub =
        _peerConnected?.listen((node) => unawaited(refresh(nodeId: node)));
    await refresh();
  }

  /// Fetches the manifest of [nodeId], or of every active member, and any
  /// index whose revision changed. Never throws.
  Future<void> refresh({String? nodeId}) {
    if (_disposed) return Future.value();
    if (nodeId == null) {
      _queuedAll = true;
    } else {
      _queuedNodes.add(nodeId.toLowerCase());
    }
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  Future<void> _drain() async {
    while (!_disposed && (_queuedAll || _queuedNodes.isNotEmpty)) {
      final all = _queuedAll;
      final nodes = {..._queuedNodes};
      _queuedAll = false;
      _queuedNodes.clear();
      try {
        await _refreshOnce(all ? null : nodes);
      } catch (e) {
        debugPrint('[PeerFilesClient] Refresh failed: $e');
      }
    }
  }

  Future<void> _refreshOnce(Set<String>? only) async {
    final members = _sync.activeMemberIds();
    // A revoked host's accounts go, and every account once this device
    // leaves the group (no members then).
    final active = {for (final m in members) m.toLowerCase()};
    for (final entry in _lent.entries.toList()) {
      if (!active.contains(entry.value.nodeId.toLowerCase())) {
        await _drop(entry.key);
      }
    }
    _publish();
    final targets = [
      for (final m in members)
        if (only == null || only.contains(m.toLowerCase())) m,
    ];
    // Concurrently, so one member that does not answer holds up no other.
    await Future.wait([for (final m in targets) _refreshMember(m)]);
    _publish();
  }

  Future<void> _refreshMember(String nodeId) async {
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      final proof = _sync.authProofForSelf();
      if (proof == null || _disposed) return;
      final manifest = await _manifest(nodeId, proof);
      // Unreachable, or refusing: keep what it lent last time.
      if (manifest == null) return;
      if (!await _apply(nodeId, proof, manifest)) return;
    }
  }

  Future<List<FlutterWireSharedAccount>?> _manifest(
      String nodeId, String proof) async {
    try {
      final response = await _transport.sendPeerFiles(
        nodeId,
        FlutterPeerFilesRequest.manifest(authProof: proof),
      );
      if (response is FlutterPeerFilesResponse_Manifest) {
        return response.accounts;
      }
      debugPrint('[PeerFilesClient] $nodeId answered a manifest with '
          '${response.runtimeType}');
    } catch (e) {
      debugPrint('[PeerFilesClient] Manifest from $nodeId failed: $e');
    }
    return null;
  }

  /// Brings [nodeId]'s accounts in line with [manifest], and says whether
  /// a fetch met a stale revision and the manifest should be read again.
  Future<bool> _apply(
    String nodeId,
    String proof,
    List<FlutterWireSharedAccount> manifest,
  ) async {
    final localKeys = {
      for (final a in sharedFilesAccounts(_localAccounts()))
        if (filesDedupeKey(a) case final key?) key,
    };
    final shown = [
      for (final wire in manifest)
        if (!_sameAsLocalShare(wire, localKeys)) wire,
    ];
    final keep = {
      for (final w in shown) peerFilesAccountId(nodeId, w.accountId)
    };
    for (final entry in _lent.entries.toList()) {
      if (entry.value.nodeId == nodeId && !keep.contains(entry.key)) {
        await _drop(entry.key);
      }
    }

    var stale = false;
    for (final wire in shown) {
      if (_disposed) return false;
      final id = peerFilesAccountId(nodeId, wire.accountId);
      await _store.saveAccount(id, nodeId: nodeId, wire: wire);
      _lent[id] = (nodeId: nodeId, wire: wire);
      if (_store.revision(id) == wire.revision.toInt()) continue;
      final outcome = await _fetch(nodeId, proof, id, wire);
      if (outcome == _Fetch.stale) stale = true;
    }
    return stale;
  }

  /// Whether [wire] is a network share this device already has as its own
  /// account. Local folders name a folder on the host, so they never are.
  static bool _sameAsLocalShare(
      FlutterWireSharedAccount wire, Set<String> localKeys) {
    if (wire.accountId == kFilesLocalAccountId) return false;
    if (wire.kind != 'smb' && wire.kind != 'webdav') return false;
    final key = wire.dedupeKey;
    return key != null && localKeys.contains(key);
  }

  /// Reads every page of [wire] at its revision into a new generation. Any
  /// failure leaves the stored copy as it was.
  Future<_Fetch> _fetch(
    String nodeId,
    String proof,
    String localAccountId,
    FlutterWireSharedAccount wire,
  ) async {
    final pages = <FlutterWireIndexPage>[];
    String? cursor;
    try {
      do {
        final response = await _transport.sendPeerFiles(
          nodeId,
          FlutterPeerFilesRequest.indexPage(
            authProof: proof,
            accountId: wire.accountId,
            revision: wire.revision,
            cursor: cursor,
          ),
        );
        switch (response) {
          case FlutterPeerFilesResponse_IndexPage(
              :final page,
              :final nextCursor
            ):
            pages.add(page);
            cursor = nextCursor;
          case FlutterPeerFilesResponse_StaleRevision():
            return _Fetch.stale;
          case FlutterPeerFilesResponse_NotAuthorized() ||
                FlutterPeerFilesResponse_Manifest():
            debugPrint('[PeerFilesClient] $nodeId answered a page of '
                '${wire.accountId} with ${response.runtimeType}');
            return _Fetch.failed;
        }
      } while (cursor != null);
      if (_disposed || !_lent.containsKey(localAccountId)) {
        return _Fetch.failed;
      }
      await _store.replace(localAccountId, wire.revision.toInt(), pages);
      return _Fetch.done;
    } catch (e) {
      debugPrint('[PeerFilesClient] Fetching ${wire.accountId} from $nodeId '
          'failed: $e');
      return _Fetch.failed;
    }
  }

  Future<void> _drop(String localAccountId) async {
    _lent.remove(localAccountId);
    await _store.remove(localAccountId);
  }

  void _publish() {
    if (_disposed) return;
    final next = [
      for (final MapEntry(key: id, value: lent) in _lent.entries)
        if (_store.revision(id) != null)
          PeerSharedAccount(
            nodeId: lent.nodeId,
            deviceName: _sync.member(lent.nodeId)?.deviceName ?? lent.nodeId,
            wire: lent.wire,
          ),
    ]..sort((a, b) {
        final byDevice = a.deviceName.compareTo(b.deviceName);
        if (byDevice != 0) return byDevice;
        final byName = a.wire.name.compareTo(b.wire.name);
        return byName != 0
            ? byName
            : a.localAccountId.compareTo(b.localAccountId);
      });
    if (!listEquals(next, _accounts.value)) _accounts.value = next;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stateSub?.cancel());
    unawaited(_connectedSub?.cancel());
    _stateSub = null;
    _connectedSub = null;
    _accounts.dispose();
  }
}

final peerFilesClientProvider = Provider<PeerFilesClient>((ref) {
  final p2p = ref.watch(p2pServiceProvider);
  final client = PeerFilesClient(
    transport: P2pPeerFilesTransport(p2p),
    sync: ref.watch(peerSyncServiceProvider),
    store: ref.watch(peerFilesStoreProvider),
    localAccounts: () =>
        ref.read(sourceRecordsProvider).value?.accounts ?? const [],
    peerConnected: p2p.onPeerConnected,
  );
  ref.onDispose(client.dispose);
  return client;
});
