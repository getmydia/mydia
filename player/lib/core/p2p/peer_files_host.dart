/// Lends this player's files libraries to the other members of its sync
/// group: the manifest and index pages they browse, the grants that let
/// Rust serve a file's bytes, and the allowlist of who may read them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../../native/lib.dart';
import '../sources/files/backend/file_system_backend.dart';
import '../sources/files/files_account.dart';
import '../sources/files/files_media_source.dart';
import '../sources/files/files_providers.dart' show filesIndexProvider;
import '../sources/files/files_queries.dart' show filesBackendPath;
import '../sources/files/index/file_library_index.dart';
import '../sources/files/smb_addresses.dart' show isIpLiteral;
import '../sources/source.dart';
import '../sources/sources_providers.dart'
    show mediaSourceProvider, sourceRecordsProvider;
import '../sources/store/source_records.dart';
import 'p2p_service.dart';
import 'peer_files_transport.dart';
import 'peer_files_wire.dart';
import 'peer_sync_service.dart';

/// One counter per files account, bumped whenever what its index pages
/// say changes, so a paired player fetching the pages notices.
abstract interface class PeerFilesRevisions {
  /// 0 for an account never bumped.
  int revision(String accountId);

  /// Moves [accountId]'s revision forward and stores it, returning the new
  /// one.
  Future<int> bump(String accountId);
}

/// The revision a bump moves [current] to: one more, but never less than
/// the clock in milliseconds. A viewer keeps the revision it fetched at, so
/// a counter that starts over (the in-memory fallback on every launch, the
/// box after a reinstall) must not hand out a number it may already hold
/// for a different index. Starting from the clock puts every new number
/// past any handed out before the reset.
int nextPeerFilesRevision(int current, int nowMs) =>
    current + 1 > nowMs ? current + 1 : nowMs;

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

class HivePeerFilesRevisions implements PeerFilesRevisions {
  HivePeerFilesRevisions(this._box, {int Function() nowMs = _nowMs})
      : _now = nowMs;

  static const boxName = 'peer_files_revisions';

  final Box<int> _box;
  final int Function() _now;

  @override
  int revision(String accountId) => _box.get(accountId) ?? 0;

  @override
  Future<int> bump(String accountId) async {
    final next = nextPeerFilesRevision(revision(accountId), _now());
    await _box.put(accountId, next);
    return next;
  }
}

class InMemoryPeerFilesRevisions implements PeerFilesRevisions {
  InMemoryPeerFilesRevisions({int Function() nowMs = _nowMs}) : _now = nowMs;

  final _revisions = <String, int>{};
  final int Function() _now;

  @override
  int revision(String accountId) => _revisions[accountId] ?? 0;

  @override
  Future<int> bump(String accountId) async => _revisions[accountId] =
      nextPeerFilesRevision(revision(accountId), _now());
}

/// Accounts derived from another member's share carry this prefix: a
/// lent library is never lent onward.
final _peerAccountId = RegExp(r'^p[0-9a-f]{12}_');

/// This player's own Files accounts, never one it borrowed from a peer.
/// What dedupe compares against, hidden or not.
List<SourceAccountRecord> sharedFilesAccounts(
        Iterable<SourceAccountRecord> accounts) =>
    [
      for (final a in accounts)
        if (a.account.kind == SourceKind.files &&
            !_peerAccountId.hasMatch(a.account.id))
          a,
    ];

/// Whether [record] has a server hidden behind the app lock.
bool hasHiddenServer(SourceAccountRecord record) =>
    record.serverLocks.values.contains(SourceLock.hidden);

/// The files accounts this player lends: [sharedFilesAccounts] minus any
/// with a hidden server. Hidden means no trace on this device while it is
/// locked, so it is never lent, locked or not: a paired device has no app
/// lock of this device's to respect.
List<SourceAccountRecord> lentFilesAccounts(
        Iterable<SourceAccountRecord> accounts) =>
    [
      for (final a in sharedFilesAccounts(accounts))
        if (!hasHiddenServer(a)) a,
    ];

/// The wire kind of a files account: `local`, `smb` or `webdav`.
String filesAccountKind(String accountId) {
  if (accountId == kFilesLocalAccountId) return 'local';
  if (isSmbAccountId(accountId)) return 'smb';
  return 'webdav';
}

/// What says two files accounts are the same share, whoever stored them:
/// [normalizeSmbUrl] of an SMB share (host, port and share name), or
/// [normalizeWebDavUrl] of a WebDAV base. Folders on a device have none,
/// since a path names a different folder on every device.
///
/// An SMB account keeps every address its share answered at, the last one
/// that answered first. A hostname is preferred over an IP literal so two
/// devices that reached the share by different addresses still agree.
String? filesDedupeKey(SourceAccountRecord record) {
  final id = record.account.id;
  if (id == kFilesLocalAccountId) return null;
  final connections = [
    for (final s in record.servers) ...s.connections,
  ];
  if (connections.isEmpty) return null;
  if (isSmbAccountId(id)) {
    final named =
        connections.where((c) => !isIpLiteral(c.uri.host)).firstOrNull;
    return normalizeSmbUrl((named ?? connections.first).uri);
  }
  return normalizeWebDavUrl(connections.first.uri);
}

/// Answers paired players' requests for this device's files libraries.
///
/// Index reads (`Manifest`, `IndexPage`) are authorized here, with the same
/// two checks PeerSync makes ([PeerSyncService.authorizes]). Byte reads are
/// authorized in Rust against the member allowlist this pushes, and each
/// path a read names is authorized here once, when Rust asks for its grant.
class PeerFilesHost {
  PeerFilesHost({
    required PeerFilesTransport transport,
    required PeerSyncService sync,
    required PeerFilesRevisions revisions,
    required List<SourceAccountRecord> Function() accounts,
    required FileLibraryIndex Function(String accountId) indexFor,
    required FileSystemBackend? Function(String accountId) backendFor,
    int pageBudget = peerFilesPageBudget,
  })  : _transport = transport,
        _sync = sync,
        _revisions = revisions,
        _accounts = accounts,
        _indexFor = indexFor,
        _backendFor = backendFor,
        _pageBudget = pageBudget;

  final PeerFilesTransport _transport;
  final PeerSyncService _sync;
  final PeerFilesRevisions _revisions;
  final List<SourceAccountRecord> Function() _accounts;
  final FileLibraryIndex Function(String accountId) _indexFor;
  final FileSystemBackend? Function(String accountId) _backendFor;
  final int _pageBudget;

  StreamSubscription<FlutterInboundPeerFilesRequest>? _requestSub;
  StreamSubscription<FlutterPeerFileGrantRequest>? _grantSub;
  StreamSubscription<void>? _stateSub;

  /// The list Rust last accepted. Recorded only once a push succeeds, so a
  /// failed one is tried again on the next state change.
  List<String>? _pushedMembers;

  /// The push in flight, and whether the roster changed since it read it.
  Future<void>? _pushing;
  bool _pushAgain = false;

  /// Listens for requests, then pushes the allowlist, and again on every
  /// change to the group. Outside a group the list is empty, so nothing is
  /// served.
  Future<void> start() async {
    if (_requestSub != null) return;
    _requestSub = _transport.onPeerFilesRequest.listen(_onRequest);
    _grantSub = _transport.onPeerFileGrantRequest.listen(_onGrantRequest);
    _stateSub = _sync.onStateChanged.listen((_) => unawaited(_pushMembers()));
    await _pushMembers();
  }

  /// Bumps [accountId]'s revision and drops Rust's grants for it, so a
  /// viewer fetching pages starts over and a moved file resolves anew.
  /// Never throws: sharing must not fail the scan or pin that called it.
  ///
  /// Then nudges the members with a (throttled) sync round. Each member
  /// that receives it notifies its sync state, which is what refreshes its
  /// [PeerFilesClient], so a viewer with the library open sees the new
  /// index without waiting for an unrelated sync.
  Future<void> bumpRevision(String accountId) async {
    try {
      await _revisions.bump(accountId);
      await _transport.invalidatePeerFileGrants(accountId);
    } catch (e) {
      debugPrint('[PeerFilesHost] Revision bump for $accountId failed: $e');
    }
    try {
      await _sync.notifyLocalMutation(throttle: true);
    } catch (e) {
      debugPrint('[PeerFilesHost] Nudging members failed: $e');
    }
  }

  /// Pushes the allowlist, one push at a time. A change that arrives while
  /// a push is in flight is not compared against [_pushedMembers], which
  /// does not yet hold what that push sends: it marks the loop to read the
  /// roster again once the push lands. Otherwise a revocation during a push
  /// of the old list would match the list before it and be skipped, leaving
  /// Rust allowing the revoked device.
  Future<void> _pushMembers() {
    if (_pushing case final running?) {
      _pushAgain = true;
      return running;
    }
    return _pushing = _pushLoop().whenComplete(() => _pushing = null);
  }

  Future<void> _pushLoop() async {
    do {
      _pushAgain = false;
      final members = _sync.activeMemberIds();
      if (_pushedMembers case final last? when listEquals(last, members)) {
        continue;
      }
      try {
        await _transport.setPeerFilesMembers(members);
        _pushedMembers = members;
      } catch (e) {
        _pushedMembers = null;
        debugPrint('[PeerFilesHost] Pushing the member allowlist failed: $e');
      }
    } while (_pushAgain);
  }

  /// The accounts a `Manifest` lists, each with its revision and dedupe key.
  List<FlutterWireSharedAccount> manifestAccounts() => [
        for (final a in lentFilesAccounts(_accounts()))
          FlutterWireSharedAccount(
            accountId: a.account.id,
            kind: filesAccountKind(a.account.id),
            name: a.account.displayName,
            dedupeKey: filesDedupeKey(a),
            revision: BigInt.from(_revisions.revision(a.account.id)),
          ),
      ];

  SourceAccountRecord? _shared(String accountId) =>
      lentFilesAccounts(_accounts())
          .where((a) => a.account.id == accountId)
          .firstOrNull;

  Future<void> _onRequest(FlutterInboundPeerFilesRequest request) async {
    FlutterPeerFilesResponse response;
    try {
      response = _answer(request);
    } catch (e) {
      // Always answer, or the viewer waits out its timeout. A stale
      // revision sends it back to the manifest, which is the retry.
      debugPrint('[PeerFilesHost] ${request.requestId} failed: $e');
      response = const FlutterPeerFilesResponse.staleRevision();
    }
    try {
      await _transport.respondToPeerFiles(request.requestId, response);
    } catch (e) {
      debugPrint('[PeerFilesHost] Answering ${request.requestId} failed: $e');
    }
  }

  FlutterPeerFilesResponse _answer(FlutterInboundPeerFilesRequest request) {
    const refused = FlutterPeerFilesResponse.notAuthorized();
    const stale = FlutterPeerFilesResponse.staleRevision();
    // A revoked device cannot sync, so its own roster never learns it was
    // removed; this is where it does. The roster marking it revoked is the
    // evidence, whatever its proof and whether or not this device's secret
    // loaded. iroh authenticated the node id, so this tells a node only
    // about itself.
    if (_sync.member(request.peer)?.revoked ?? false) {
      return const FlutterPeerFilesResponse.revoked();
    }
    switch (request.request) {
      case FlutterPeerFilesRequest_Manifest(:final authProof):
        if (!_sync.authorizes(request.peer, authProof)) return refused;
        return FlutterPeerFilesResponse.manifest(accounts: manifestAccounts());
      case FlutterPeerFilesRequest_IndexPage(
          :final authProof,
          :final accountId,
          :final revision,
          :final cursor,
        ):
        if (!_sync.authorizes(request.peer, authProof)) return refused;
        // An account no longer lent reads as changed: the viewer fetches
        // the manifest again and finds it gone.
        if (_shared(accountId) == null) return stale;
        if (BigInt.from(_revisions.revision(accountId)) != revision) {
          return stale;
        }
        final start = cursor == null ? 0 : int.tryParse(cursor);
        if (start == null || start < 0) return stale;
        // No await between the revision check and the read: a bump cannot
        // land in between.
        final slice =
            indexPageFrom(_indexFor(accountId), start, budget: _pageBudget);
        return FlutterPeerFilesResponse.indexPage(
          page: slice.page,
          nextCursor: slice.next?.toString(),
        );
    }
  }

  Future<void> _onGrantRequest(FlutterPeerFileGrantRequest request) async {
    FlutterPeerFileGrantAnswer answer;
    try {
      answer = await _grantFor(request.accountId, request.path);
    } catch (e) {
      // The path may well be shared: a 404 would tell the viewer the file
      // is gone. A 502 says the host could not serve it right now.
      debugPrint('[PeerFilesHost] Grant ${request.requestId} failed: $e');
      answer = const FlutterPeerFileGrantAnswer.failed();
    }
    try {
      await _transport.respondPeerFileGrant(request.requestId, answer);
    } catch (e) {
      debugPrint('[PeerFilesHost] Answering grant ${request.requestId} '
          'failed: $e');
    }
  }

  /// Not shared (404) when the path is not one this device lends, or its
  /// backend says the file is gone. Failed (502) when it is lent but its
  /// backend cannot be built or reached: the file is there, its share is
  /// not answering.
  Future<FlutterPeerFileGrantAnswer> _grantFor(
      String accountId, String path) async {
    const notShared = FlutterPeerFileGrantAnswer.notShared();
    const failed = FlutterPeerFileGrantAnswer.failed();
    if (_sync.activeMemberIds().isEmpty) return notShared;
    if (_shared(accountId) == null) return notShared;
    if (!_indexedPath(_indexFor(accountId), path)) return notShared;
    final backend = _backendFor(accountId);
    if (backend == null) return failed;
    try {
      final playable = await backend.playable(path);
      return FlutterPeerFileGrantAnswer.granted(
        grant: FlutterPeerFileGrant(
          url: playable.url,
          headers: [for (final h in playable.headers.entries) (h.key, h.value)],
        ),
      );
    } on BackendNotFound catch (e) {
      debugPrint('[PeerFilesHost] A read in $accountId names a gone file: $e');
      return notShared;
    } on BackendFailure catch (e) {
      debugPrint('[PeerFilesHost] No grant for a read in $accountId: $e');
      return failed;
    }
  }

  /// Whether [path] is an indexed file of [index] or one of its sidecars.
  ///
  /// The index stores both relative to their root. A read names the full
  /// backend path, [filesBackendPath] of the root and the relative path:
  /// the form the files source hands `playable()` for a video and, through
  /// `MediaStreamInfo.externalPath`, for a subtitle sidecar. Only that form
  /// passes, compared exactly, so the root is never in doubt and nothing a
  /// caller writes (`..`, another root, another account) can reach past the
  /// index.
  static bool _indexedPath(FileLibraryIndex index, String path) {
    final roots = {for (final r in index.roots()) r.id: r};
    for (final f in index.files().values) {
      final root = roots[f.rootId];
      if (root == null) continue;
      if (filesBackendPath(root, f.path) == path) return true;
      for (final s in f.sidecars) {
        if (filesBackendPath(root, s) == path) return true;
      }
    }
    return false;
  }

  void dispose() {
    unawaited(_requestSub?.cancel());
    unawaited(_grantSub?.cancel());
    unawaited(_stateSub?.cancel());
    _requestSub = null;
    _grantSub = null;
    _stateSub = null;
  }
}

/// The revision store, over its Hive box when that is open (it is opened
/// with the files library boxes at startup), in memory otherwise.
final peerFilesRevisionsProvider = Provider<PeerFilesRevisions>((ref) {
  if (Hive.isBoxOpen(HivePeerFilesRevisions.boxName)) {
    return HivePeerFilesRevisions(
        Hive.box<int>(HivePeerFilesRevisions.boxName));
  }
  return InMemoryPeerFilesRevisions();
});

final peerFilesHostProvider = Provider<PeerFilesHost>((ref) {
  List<SourceAccountRecord> stored() =>
      ref.read(sourceRecordsProvider).value?.accounts ?? const [];
  final host = PeerFilesHost(
    transport: P2pPeerFilesTransport(ref.watch(p2pServiceProvider)),
    sync: ref.watch(peerSyncServiceProvider),
    revisions: ref.watch(peerFilesRevisionsProvider),
    accounts: stored,
    indexFor: (id) => ref.read(filesIndexProvider(id)),
    // The account's own source and its backend, the one its playback and
    // scans use. None while the source cannot be built (its storage failed
    // to open, say): the read is then answered 502.
    backendFor: (id) {
      final record = stored().where((a) => a.account.id == id).firstOrNull;
      final source =
          record?.sources.where((s) => s.profile.isOwner).firstOrNull;
      if (source == null) return null;
      final media = ref.read(mediaSourceProvider(source.id));
      return media is FilesMediaSource ? media.backend : null;
    },
  );
  ref.onDispose(host.dispose);
  return host;
});
