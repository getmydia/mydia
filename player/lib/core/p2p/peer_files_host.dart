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

  /// Increments and stores [accountId]'s revision, returning the new one.
  Future<int> bump(String accountId);
}

class HivePeerFilesRevisions implements PeerFilesRevisions {
  HivePeerFilesRevisions(this._box);

  static const boxName = 'peer_files_revisions';

  final Box<int> _box;

  @override
  int revision(String accountId) => _box.get(accountId) ?? 0;

  @override
  Future<int> bump(String accountId) async {
    final next = revision(accountId) + 1;
    await _box.put(accountId, next);
    return next;
  }
}

class InMemoryPeerFilesRevisions implements PeerFilesRevisions {
  final _revisions = <String, int>{};

  @override
  int revision(String accountId) => _revisions[accountId] ?? 0;

  @override
  Future<int> bump(String accountId) async =>
      _revisions[accountId] = revision(accountId) + 1;
}

/// Accounts derived from another member's share carry this prefix: a
/// lent library is never lent onward.
final _peerAccountId = RegExp(r'^p[0-9a-f]{12}_');

/// The files accounts this player lends: its own Files libraries, never
/// one it borrowed from a peer.
List<SourceAccountRecord> sharedFilesAccounts(
        Iterable<SourceAccountRecord> accounts) =>
    [
      for (final a in accounts)
        if (a.account.kind == SourceKind.files &&
            !_peerAccountId.hasMatch(a.account.id))
          a,
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
  List<String>? _pushedMembers;

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
  Future<void> bumpRevision(String accountId) async {
    try {
      await _revisions.bump(accountId);
      await _transport.invalidatePeerFileGrants(accountId);
    } catch (e) {
      debugPrint('[PeerFilesHost] Revision bump for $accountId failed: $e');
    }
  }

  Future<void> _pushMembers() async {
    final members = _sync.activeMemberIds();
    if (_pushedMembers case final last? when listEquals(last, members)) {
      return;
    }
    _pushedMembers = members;
    try {
      await _transport.setPeerFilesMembers(members);
    } catch (e) {
      debugPrint('[PeerFilesHost] Pushing the member allowlist failed: $e');
    }
  }

  SourceAccountRecord? _shared(String accountId) =>
      sharedFilesAccounts(_accounts())
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
    switch (request.request) {
      case FlutterPeerFilesRequest_Manifest(:final authProof):
        if (!_sync.authorizes(request.peer, authProof)) return refused;
        return FlutterPeerFilesResponse.manifest(accounts: [
          for (final a in sharedFilesAccounts(_accounts()))
            FlutterWireSharedAccount(
              accountId: a.account.id,
              kind: filesAccountKind(a.account.id),
              name: a.account.displayName,
              dedupeKey: filesDedupeKey(a),
              revision: BigInt.from(_revisions.revision(a.account.id)),
            ),
        ]);
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
    FlutterPeerFileGrant? grant;
    try {
      grant = await _grantFor(request.accountId, request.path);
    } catch (e) {
      debugPrint('[PeerFilesHost] Grant ${request.requestId} failed: $e');
      grant = null;
    }
    try {
      await _transport.respondPeerFileGrant(request.requestId, grant);
    } catch (e) {
      debugPrint('[PeerFilesHost] Answering grant ${request.requestId} '
          'failed: $e');
    }
  }

  Future<FlutterPeerFileGrant?> _grantFor(String accountId, String path) async {
    if (_sync.activeMemberIds().isEmpty) return null;
    if (_shared(accountId) == null) return null;
    if (!_indexedPath(_indexFor(accountId), path)) return null;
    final backend = _backendFor(accountId);
    if (backend == null) return null;
    try {
      final playable = await backend.playable(path);
      return FlutterPeerFileGrant(
        url: playable.url,
        headers: [for (final h in playable.headers.entries) (h.key, h.value)],
      );
    } on BackendFailure catch (e) {
      debugPrint('[PeerFilesHost] No grant for a read in $accountId: $e');
      return null;
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
    // scans use. None while the source cannot be built (locked away, or
    // its storage failed to open): the read is then refused.
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
