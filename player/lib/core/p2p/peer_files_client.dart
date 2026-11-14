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

enum _Fetch { done, stale, failed, revoked }

/// A host's answer to a manifest request: what it lends, or that it marks
/// this device revoked. Null accounts and not revoked: no answer to use.
typedef _Manifest = ({List<FlutterWireSharedAccount>? accounts, bool revoked});

/// Keeps [accounts] and the store in step with what each active member
/// lends.
///
/// Refreshes on [start], on every change to the sync group's state (which
/// includes each completed sync round), when a member connects, when this
/// device's own files accounts change, and on [refresh]. Refreshes run one at
/// a time; one asked for while another runs waits for it and then runs once
/// for everything asked meanwhile.
///
/// A copy is deleted only on positive evidence: its host is marked revoked
/// in the roster, this device completed leaving the group, the host's
/// manifest no longer lists the account, or the host answers `Revoked`
/// (its roster marks this device revoked, which this device's own roster
/// never learns: a revoked device cannot sync). An empty member list
/// proves nothing (the group secret may simply not have loaded), and
/// neither does `NotAuthorized`, so neither deletes anything.
class PeerFilesClient {
  PeerFilesClient({
    required PeerFilesTransport transport,
    required PeerSyncService sync,
    required PeerFilesStore store,
    required List<SourceAccountRecord>? Function() localAccounts,
    Future<void> Function()? localAccountsReady,
    Stream<void>? localAccountsChanged,
    Stream<String>? peerConnected,
  })  : _transport = transport,
        _sync = sync,
        _store = store,
        _localAccounts = localAccounts,
        _localAccountsReady = localAccountsReady,
        _localAccountsChanged = localAccountsChanged,
        _peerConnected = peerConnected;

  /// How many times one member's fetch goes back to the manifest after a
  /// `StaleRevision`, before keeping the copy it has until the next refresh.
  static const maxRestarts = 2;

  /// How long [start] waits for this device's accounts before refreshing
  /// anyway, deciding nothing that needs them.
  static const localAccountsWait = Duration(seconds: 30);

  final PeerFilesTransport _transport;
  final PeerSyncService _sync;
  final PeerFilesStore _store;

  /// This device's accounts, null while they have not loaded or failed to.
  final List<SourceAccountRecord>? Function() _localAccounts;
  final Future<void> Function()? _localAccountsReady;
  final Stream<void>? _localAccountsChanged;
  final Stream<String>? _peerConnected;

  final _accounts = ValueNotifier<List<PeerSharedAccount>>(const []);
  ValueListenable<List<PeerSharedAccount>> get accounts => _accounts;

  /// Each lent account by its local id: who lends it and its latest
  /// manifest entry. Accounts with no index yet are held here but not shown.
  final _lent = <String, ({String nodeId, FlutterWireSharedAccount wire})>{};

  final _subs = <StreamSubscription<Object?>>[];
  bool _started = false;
  bool _disposed = false;

  /// The dedupe keys the last refresh decided with, so a change to this
  /// device's accounts that does not move them costs no refresh.
  Set<String>? _decidedLocalKeys;

  Future<void>? _running;
  bool _queuedLeave = false;
  bool _queuedAll = false;
  final _queuedNodes = <String>{};

  /// Shows what the store kept from earlier launches, then listens and
  /// refreshes. Call it only once peer sync has started successfully.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await _store.sweep();
    } catch (e) {
      debugPrint('[PeerFilesClient] Sweeping leftovers failed: $e');
    }
    for (final a in _store.storedAccounts()) {
      if (_revoked(a.nodeId)) {
        // A failed delete must not stop the client starting: the copy is
        // not shown (its host is revoked) and the next start tries again.
        try {
          await _store.remove(a.localAccountId);
        } catch (e) {
          debugPrint('[PeerFilesClient] Removing a revoked copy failed: $e');
        }
      } else {
        _lent[a.localAccountId] = (nodeId: a.nodeId, wire: a.wire);
      }
    }
    _publish();
    _subs.addAll([
      _sync.onStateChanged.listen((_) => unawaited(refresh())),
      _sync.onLeftGroup.listen((_) => unawaited(_leave())),
      if (_peerConnected case final s?)
        s.listen((node) => unawaited(refresh(nodeId: node))),
      if (_localAccountsChanged case final s?)
        s.listen((_) => _onLocalAccountsChanged()),
    ]);
    try {
      await _localAccountsReady?.call().timeout(localAccountsWait);
    } catch (e) {
      debugPrint('[PeerFilesClient] Local accounts not loaded: $e');
    }
    if (_disposed) return;
    await refresh();
  }

  /// Fetches the manifest of [nodeId], or of every active member, and any
  /// index whose revision changed. Never throws.
  Future<void> refresh({String? nodeId}) {
    if (nodeId == null) {
      _queuedAll = true;
    } else {
      _queuedNodes.add(nodeId.toLowerCase());
    }
    return _kick();
  }

  /// This device left the group: every copy goes.
  Future<void> _leave() {
    _queuedLeave = true;
    return _kick();
  }

  Future<void> _kick() {
    if (_disposed) return Future.value();
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  void _onLocalAccountsChanged() {
    if (_disposed) return;
    _publish();
    final keys = _localKeys();
    if (keys == null || setEquals(keys, _decidedLocalKeys)) return;
    unawaited(refresh());
  }

  Future<void> _drain() async {
    while (
        !_disposed && (_queuedLeave || _queuedAll || _queuedNodes.isNotEmpty)) {
      try {
        if (_queuedLeave) {
          _queuedLeave = false;
          for (final id in _lent.keys.toList()) {
            await _drop(id);
          }
          _publish();
          continue;
        }
        final all = _queuedAll;
        final nodes = {..._queuedNodes};
        _queuedAll = false;
        _queuedNodes.clear();
        await _refreshOnce(all ? null : nodes);
      } catch (e) {
        debugPrint('[PeerFilesClient] Refresh failed: $e');
      }
    }
  }

  /// Whether the roster marks [nodeId] revoked. A node it does not hold is
  /// not, since that is no evidence of anything.
  bool _revoked(String nodeId) => _sync.member(nodeId)?.revoked ?? false;

  /// This device's SMB and WebDAV dedupe keys, null while its accounts are
  /// unknown.
  Set<String>? _localKeys() {
    final local = _localAccounts();
    if (local == null) return null;
    return {
      for (final a in sharedFilesAccounts(local))
        if (filesDedupeKey(a) case final key?) key,
    };
  }

  Future<void> _refreshOnce(Set<String>? only) async {
    for (final entry in _lent.entries.toList()) {
      if (_revoked(entry.value.nodeId)) await _drop(entry.key);
    }
    _publish();
    final localKeys = _localKeys();
    if (localKeys != null) _decidedLocalKeys = localKeys;
    final targets = [
      for (final m in _sync.activeMemberIds())
        if (only == null || only.contains(m.toLowerCase())) m,
    ];
    // Concurrently, so one member that does not answer holds up no other.
    await Future.wait([for (final m in targets) _refreshMember(m, localKeys)]);
    _publish();
  }

  Future<void> _refreshMember(String nodeId, Set<String>? localKeys) async {
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      final proof = _sync.authProofForSelf();
      if (proof == null || _disposed) return;
      final manifest = await _manifest(nodeId, proof);
      if (manifest.revoked) {
        await _dropHost(nodeId);
        return;
      }
      // Unreachable, or refusing: keep what it lent last time.
      final accounts = manifest.accounts;
      if (accounts == null) return;
      if (!await _apply(nodeId, proof, accounts, localKeys)) return;
    }
  }

  Future<_Manifest> _manifest(String nodeId, String proof) async {
    try {
      final response = await _transport.sendPeerFiles(
        nodeId,
        FlutterPeerFilesRequest.manifest(authProof: proof),
      );
      switch (response) {
        case FlutterPeerFilesResponse_Manifest(:final accounts):
          return (accounts: accounts, revoked: false);
        case FlutterPeerFilesResponse_Revoked():
          debugPrint('[PeerFilesClient] $nodeId revoked this device');
          return (accounts: null, revoked: true);
        default:
          debugPrint('[PeerFilesClient] $nodeId answered a manifest with '
              '${response.runtimeType}');
      }
    } catch (e) {
      debugPrint('[PeerFilesClient] Manifest from $nodeId failed: $e');
    }
    return (accounts: null, revoked: false);
  }

  /// Deletes every copy [nodeId] lent, for a host that revoked this device.
  Future<void> _dropHost(String nodeId) async {
    final node = nodeId.toLowerCase();
    for (final entry in _lent.entries.toList()) {
      if (entry.value.nodeId.toLowerCase() == node) await _drop(entry.key);
    }
  }

  /// Brings [nodeId]'s accounts in line with [manifest], and says whether
  /// a fetch met a stale revision and the manifest should be read again.
  ///
  /// With [localKeys] unknown, a share that might duplicate one of this
  /// device's is left exactly as it was: not fetched, not dropped.
  Future<bool> _apply(
    String nodeId,
    String proof,
    List<FlutterWireSharedAccount> manifest,
    Set<String>? localKeys,
  ) async {
    final keep = <String>{};
    final wanted = <FlutterWireSharedAccount>[];
    for (final wire in manifest) {
      final id = peerFilesAccountId(nodeId, wire.accountId);
      if (_dedupable(wire)) {
        if (localKeys == null) {
          keep.add(id);
          continue;
        }
        if (localKeys.contains(wire.dedupeKey)) continue;
      }
      keep.add(id);
      wanted.add(wire);
    }
    final node = nodeId.toLowerCase();
    for (final entry in _lent.entries.toList()) {
      if (entry.value.nodeId.toLowerCase() == node &&
          !keep.contains(entry.key)) {
        await _drop(entry.key);
      }
    }

    var stale = false;
    for (final wire in wanted) {
      if (_disposed) return false;
      final id = peerFilesAccountId(nodeId, wire.accountId);
      await _store.saveAccount(id, nodeId: nodeId, wire: wire);
      _lent[id] = (nodeId: nodeId, wire: wire);
      if (_store.revision(id) == wire.revision.toInt()) continue;
      final outcome = await _fetch(nodeId, proof, id, wire);
      if (outcome == _Fetch.stale) stale = true;
      if (outcome == _Fetch.revoked) {
        await _dropHost(nodeId);
        return false;
      }
    }
    return stale;
  }

  /// Whether [wire] is a network share that could be one this device has
  /// as its own account. Local folders name a folder on the host, so they
  /// never are.
  static bool _dedupable(FlutterWireSharedAccount wire) =>
      wire.accountId != kFilesLocalAccountId &&
      (wire.kind == 'smb' || wire.kind == 'webdav') &&
      wire.dedupeKey != null;

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
          case FlutterPeerFilesResponse_Revoked():
            return _Fetch.revoked;
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

  /// Shows each account with an index whose host the roster holds and has
  /// not revoked. A share that might duplicate one of this device's waits
  /// until this device's accounts are known and it is not one of them.
  void _publish() {
    if (_disposed) return;
    final localKeys = _localKeys();
    final next = <PeerSharedAccount>[];
    for (final MapEntry(key: id, value: lent) in _lent.entries) {
      if (_store.revision(id) == null) continue;
      final member = _sync.member(lent.nodeId);
      if (member == null || member.revoked) continue;
      if (_dedupable(lent.wire) &&
          (localKeys == null || localKeys.contains(lent.wire.dedupeKey))) {
        continue;
      }
      next.add(PeerSharedAccount(
        nodeId: lent.nodeId,
        deviceName: member.deviceName,
        wire: lent.wire,
      ));
    }
    next.sort((a, b) {
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
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _accounts.dispose();
  }
}

final peerFilesClientProvider = Provider<PeerFilesClient>((ref) {
  final p2p = ref.watch(p2pServiceProvider);
  // Every change to the stored sources, filtered down to a change of
  // dedupe keys by the client.
  final localChanges = StreamController<void>.broadcast();
  ref.listen(sourceRecordsProvider, (_, __) => localChanges.add(null));
  final client = PeerFilesClient(
    transport: P2pPeerFilesTransport(p2p),
    sync: ref.watch(peerSyncServiceProvider),
    store: ref.watch(peerFilesStoreProvider),
    localAccounts: () {
      final records = ref.read(sourceRecordsProvider);
      // A failed load is not "no accounts": deciding with an empty set would
      // fetch every peer copy of this device's own shares.
      if (records.hasError) return null;
      return records.value?.accounts;
    },
    localAccountsReady: () => ref.read(sourceRecordsProvider.future),
    localAccountsChanged: localChanges.stream,
    peerConnected: p2p.onPeerConnected,
  );
  ref.onDispose(() {
    client.dispose();
    unawaited(localChanges.close());
  });
  return client;
});
