/// Wiring for files libraries: the index box, one index per account, the
/// backends, and building a [FilesMediaSource] for a stored [Source].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;

import '../../cache/watcher_registry.dart' show invalidatorProvider;
import '../../p2p/peer_files_host.dart'
    show HivePeerFilesRevisions, peerFilesHostProvider;
import '../../p2p/media_proxy_factory.dart' show mediaProxyProvider;
import '../../p2p/p2p_service.dart' show p2pServiceProvider;
import '../../p2p/peer_files_backend.dart';
import '../../p2p/peer_files_client.dart' show peerFilesClientProvider;
import '../../p2p/peer_files_store.dart' show PeerFilesStore;
import '../../p2p/peer_files_transport.dart' show P2pPeerFilesTransport;
import '../../p2p/peer_sync_service.dart';
import '../../p2p/peer_sync_store.dart';
import '../../playback/playback_progress_store.dart';
import '../connection/connection_refresh_bus.dart';
import '../source.dart';
import '../sources_providers.dart' show sourceSecretsProvider;
import 'backend/file_system_backend.dart';
import 'backend/local_path_backend.dart';
import 'backend/smb_backend.dart';
import 'backend/webdav_backend.dart';
import 'cast/files_cast_bridge.dart';
import 'files_account.dart';
import 'files_media_source.dart';
import 'files_scan_controller.dart';
import 'index/file_library_index.dart';
import 'match/file_matcher.dart';
import 'media_names.dart';
import 'peer_files_sources.dart'
    show
        isPeerFilesSource,
        peerConnectedProvider,
        peerFilesAccountsProvider,
        peerFilesHostAccountId,
        peerFilesIndexProvider;
import 'files_accounts.dart' show filesAccountsProvider;
import 'smb_addresses.dart' show smbTargetsOf;
import 'smb_discovery.dart' show smbDiscoveryProvider;
import 'smb_native.dart' show smbNativeProvider;

/// Opens the boxes a files source reads synchronously while it builds: its
/// index, playback progress, and the peer sync store. Called at startup after
/// `initAppHive()`; Hive hands back an already-open box.
Future<void> openFilesLibraryBoxes() async {
  final indexBox =
      await Hive.openBox<Map<dynamic, dynamic>>(FileLibraryIndex.boxName);
  final progressBox = await Hive.openBox<Map<dynamic, dynamic>>(
      HivePlaybackProgressStore.boxName);
  final syncBox =
      await Hive.openBox<Map<dynamic, dynamic>>(PeerSyncStore.boxName);
  final syncStore = HivePeerSyncStore(syncBox);
  final progressStore = HivePlaybackProgressStore(progressBox);
  await seedPeerSyncStoreIfNeeded(
    syncStore: syncStore,
    indexBox: indexBox,
    progressStore: progressStore,
  );
  await openPeerFilesBoxes();
}

/// Opens the boxes peer file sharing keeps: the revisions this device
/// lends at and the copies it borrows. Each failure is its own, and none
/// fails startup: without the revisions box the counters live in memory
/// (see `peerFilesRevisionsProvider`), and without the copies box no lent
/// library shows (see `peerFilesAccountsProvider`). Neither is worth the
/// files libraries or the peer sync seeding, which run before this.
Future<void> openPeerFilesBoxes() async {
  try {
    await Hive.openBox<int>(HivePeerFilesRevisions.boxName);
  } catch (e) {
    debugPrint('[FilesSource] Peer files revisions box did not open: $e');
  }
  try {
    await Hive.openBox<Map<dynamic, dynamic>>(PeerFilesStore.boxName);
  } catch (e) {
    debugPrint('[FilesSource] Peer files copies box did not open: $e');
  }
}

/// The `files_index` box, opened by [openFilesLibraryBoxes].
final filesIndexBoxProvider = Provider<Box<Map<dynamic, dynamic>>>(
    (ref) => Hive.box<Map<dynamic, dynamic>>(FileLibraryIndex.boxName));

/// One index per account, shared by its source, its scans and the add flows:
/// a second instance would hold its own copy of the records.
final filesIndexProvider = Provider.family<FileLibraryIndex, String>(
  (ref, accountId) =>
      FileLibraryIndex(ref.watch(filesIndexBoxProvider), accountId: accountId),
);

/// The playback progress store, read synchronously. It wraps the same open
/// box `playbackProgressStoreProvider` resolves to, so both see one set of
/// records.
final filesProgressStoreProvider = Provider<PlaybackProgressStore>((ref) =>
    HivePlaybackProgressStore(
        Hive.box<Map<dynamic, dynamic>>(HivePlaybackProgressStore.boxName)));

/// The peer sync store, read synchronously. It wraps the open box
/// [PeerSyncStore.boxName] when open, falling back to an in-memory store in tests.
final peerSyncStoreProvider = Provider<PeerSyncStore>((ref) {
  if (Hive.isBoxOpen(PeerSyncStore.boxName)) {
    return HivePeerSyncStore(
        Hive.box<Map<dynamic, dynamic>>(PeerSyncStore.boxName));
  }
  return InMemoryPeerSyncStore();
});

/// Whether the boxes [openFilesLibraryBoxes] opens are there. False when
/// that failed at startup: files sources are then left out (see
/// `canBuildSource`) instead of throwing from every list that reads them.
final filesStorageOpenProvider = Provider<bool>((ref) {
  try {
    ref.read(filesIndexBoxProvider);
    ref.read(filesProgressStoreProvider);
    return true;
  } catch (e) {
    debugPrint('[FilesSource] Files library storage is not open: $e');
    return false;
  }
});

final relayTmdbProvider = Provider<RelayTmdb>((ref) => RelayTmdb());

/// Overridable so tests can tell the time a scan is due.
final filesClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

typedef FilesBackendBuilder = FileSystemBackend Function(
    Ref ref, Source source);

/// How a files source reaches its files. Tests override it with a fake.
final filesBackendBuilderProvider =
    Provider<FilesBackendBuilder>((_) => defaultFilesBackend);

/// Folders on this device probe each of the account's roots. A WebDAV or SMB
/// share reads its credentials on first use.
FileSystemBackend defaultFilesBackend(Ref ref, Source source) {
  if (isPeerFilesSource(source)) {
    final p2p = ref.read(p2pServiceProvider);
    final sync = ref.read(peerSyncServiceProvider);
    return PeerFilesBackend(
      nodeId: source.server.machineIdentifier ?? '',
      hostAccountId: peerFilesHostAccountId(source.account.id),
      proxy: ref.read(mediaProxyProvider),
      transport: P2pPeerFilesTransport(p2p),
      isConnected: p2p.isConnectedToPeer,
      addressOf: (nodeId) => sync.member(nodeId)?.endpointAddrJson,
    );
  }
  if (source.account.id == kFilesLocalAccountId ||
      source.server.connections.isEmpty) {
    final index = ref.read(filesIndexProvider(source.account.id));
    return LocalFoldersBackend(roots: index.roots);
  }
  final secrets = ref.read(sourceSecretsProvider);
  if (isSmbAccountId(source.account.id)) {
    return LazySmbBackend(
      native: ref.read(smbNativeProvider),
      accountId: source.account.id,
      targets: smbTargetsOf(source.server.connections),
      credentials: () => secrets.accountToken(source.account),
      serviceName: source.server.serviceName,
      discovery: ref.read(smbDiscoveryProvider),
      onReachedVia: (t, d) => ref
          .read(filesAccountsProvider)
          .promoteSmbAddress(source.account.id, t, discovered: d),
    );
  }
  return LazyWebDavBackend(
    base: source.server.connections.first.uri,
    credentials: () => secrets.accountToken(source.account),
  );
}

/// How long the index may go unscanned before opening the source scans it.
const kFilesRescanAfter = Duration(hours: 6);

bool filesRescanDue(DateTime? lastScanAt, DateTime now) =>
    lastScanAt == null || now.difference(lastScanAt) > kFilesRescanAfter;

/// A files source over its account's index. Probes the backend at once and
/// on every resume or network change, and starts a scan when the last one
/// is older than [kFilesRescanAfter].
///
/// A library a paired player lends reads the live copy of the host's index
/// and is rebuilt when a new copy lands. It never scans (its host does),
/// probes once, and keys sync on the host's account id.
FilesMediaSource buildFilesSource(
  Ref ref,
  Source source, {
  required void Function() onReauthNeeded,
  void Function()? onSyncMutation,
}) {
  final peer = isPeerFilesSource(source);
  final index = peer
      ? ref.watch(peerFilesIndexProvider(source.account.id))
      : ref.read(filesIndexProvider(source.account.id));
  final progress = ref.read(filesProgressStoreProvider);
  final tmdb = ref.read(relayTmdbProvider);
  final invalidator = ref.read(invalidatorProvider);
  final syncStore = ref.read(peerSyncStoreProvider);
  // Playback keeps a reporter, and with it this callback, past a rebuild of
  // this source; `ref` is disposed by then. The container is not.
  final container = ref.container;
  final syncMutation = onSyncMutation ??
      () {
        unawaited(
          container
              .read(peerSyncServiceProvider)
              .notifyLocalMutation(throttle: true),
        );
      };
  final matcher = FileMatcher(
    tmdb: tmdb,
    names: ref.read(mediaNamesProvider),
    index: index,
    progress: progress,
    sourceId: source.id,
    syncStore: syncStore,
    onSyncMutation: syncMutation,
    onGroupLanded: () =>
        invalidator.invalidate(FilesMediaSource.groupLandedTargets(source.id)),
    // Paired players browsing this library refetch it. A lent library is
    // not this device's to lend, and its matcher writes nothing.
    onPinned: peer
        ? null
        : () => unawaited(container
            .read(peerFilesHostProvider)
            .bumpRevision(source.account.id)),
    readOnly: peer,
  );
  late final FilesMediaSource media;
  // A resume or a network change probes again, and scans when the app sat
  // in the background past the rescan interval: the source is not rebuilt
  // then, so the check on open alone would not see it. A lent library is
  // probed again when its host connects instead, since reachable means
  // connected for it.
  // Node ids compare without regard to case, as the roster does.
  final hostNode = source.server.machineIdentifier?.toLowerCase();
  final StreamSubscription<Object?> events = peer
      ? ref
          .read(peerConnectedProvider)
          .where((n) => n.toLowerCase() == hostNode)
          .listen((_) => unawaited(media.probe()))
      : ref.read(connectionRefreshBusProvider).events.listen((_) {
          unawaited(media.probe());
          _scanIfDue(ref, source, index);
        });
  final backend = ref.read(filesBackendBuilderProvider)(ref, source);
  media = FilesMediaSource(
    source: source,
    backend: backend,
    index: index,
    progress: progress,
    matcher: matcher,
    tmdb: tmdb,
    syncStore: syncStore,
    onSyncMutation: syncMutation,
    onReauthNeeded: onReauthNeeded,
    invalidate: invalidator.invalidate,
    syncAccountId: peer ? peerFilesHostAccountId(source.account.id) : null,
    // Read when an error is worded, so a renamed device shows its new name.
    peerDeviceName: peer
        ? () =>
            container
                .read(peerFilesAccountsProvider)
                .where((a) => a.localAccountId == source.account.id)
                .firstOrNull
                ?.deviceName ??
            source.server.name
        : null,
    onPeerFilesChanged: peer
        ? (nodeId) => unawaited(container.read(peerFilesClientProvider).refresh(
              nodeId: nodeId,
            ))
        : null,
    // An SMB account's playback URLs outlive this source: saving new
    // credentials or a folder rebuilds it, and a playback in progress
    // streams through them. They go with the account
    // ([closeRemovedFilesAccount]), or after 12 hours unused.
    onDispose: () {
      unawaited(events.cancel());
      if (backend is LazyWebDavBackend) backend.close();
    },
  );
  unawaited(media.probe());
  if (!peer) _scanIfDue(ref, source, index);
  return media;
}

/// LAN HTTP range bridge used when casting a `SourceKind.files` item to a
/// Chromecast or DLNA receiver.
final filesCastBridgeProvider = Provider<FilesCastBridge>((ref) {
  final bridge = FilesCastBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});

/// Forgets a removed SMB account's playback URLs and closes its connections.
/// Anything else, or a failure, is left alone: leftover URLs expire unused.
Future<void> closeRemovedFilesAccount(Ref ref, String accountId) async {
  if (!isSmbAccountId(accountId)) return;
  try {
    await ref.read(smbNativeProvider).closeAccount(accountId);
  } catch (e) {
    debugPrint('[FilesSource] Could not close the SMB account: $e');
  }
}

/// Starts a scan when the last one is older than [kFilesRescanAfter]. A
/// scan already running is left to finish, with nothing queued after it.
void _scanIfDue(Ref ref, Source source, FileLibraryIndex index) {
  if (!filesRescanDue(index.lastScanAt(), ref.read(filesClockProvider)())) {
    return;
  }
  // After this build: the scan reads the source back from its provider.
  scheduleMicrotask(() {
    if (!ref.mounted) return;
    final scan = ref.read(filesScanProvider(source.id).notifier);
    if (ref.read(filesScanProvider(source.id)).running) return;
    unawaited(scan.rescan().catchError((Object e) {
      debugPrint('[FilesSource] Scan on open failed: $e');
    }));
  });
}

/// Folders on this device: plain paths, and a probe that checks every root,
/// so a drive that is unplugged or a folder that is gone shows as
/// unreachable. A root that refuses access wins over one that is missing,
/// since only the first asks the viewer to choose the folder again.
class LocalFoldersBackend implements FileSystemBackend {
  LocalFoldersBackend({required this.roots});

  final List<LibraryRoot> Function() roots;
  final _files = LocalPathBackend();

  @override
  Future<List<FileEntry>> list(String dir) => _files.list(dir);

  @override
  Future<FileEntry?> stat(String path) => _files.stat(path);

  @override
  Future<PlayableFile> playable(String path) => _files.playable(path);

  @override
  Future<void> probe() async {
    BackendFailure? failure;
    for (final r in roots()) {
      try {
        await LocalPathBackend(root: r.path).probe();
      } on BackendFailure catch (e) {
        if (failure == null || e is BackendPermissionLost) failure = e;
      }
    }
    if (failure != null) throw failure;
  }
}

/// A [WebDavBackend] built on first use from the stored credentials. A
/// missing or unreadable credential is a refused one, and a refused call
/// drops the built backend, so the next call reads the credentials again
/// (after the viewer signs in anew).
///
/// Every backend it builds shares one HTTP client, so dropping one leaks
/// nothing and a request still in flight on it finishes. [close] closes that
/// client unless it was given one, which its owner closes.
class LazyWebDavBackend implements FileSystemBackend {
  LazyWebDavBackend({
    required this.base,
    required this.credentials,
    http.Client? client,
  })  : _owned = client == null ? http.Client() : null,
        _given = client;

  final Uri base;
  final Future<String?> Function() credentials;
  final http.Client? _owned;
  final http.Client? _given;
  Future<WebDavBackend>? _backend;

  http.Client get _client => (_given ?? _owned)!;

  /// Closes the client this backend made. Called when its source goes.
  void close() => _owned?.close();

  Future<T> _call<T>(Future<T> Function(WebDavBackend b) run) async {
    final b = await _resolve();
    try {
      return await run(b);
    } on BackendUnauthorized {
      _backend = null;
      rethrow;
    }
  }

  Future<WebDavBackend> _resolve() => _backend ??= _build().then(
        (b) => b,
        onError: (Object e, StackTrace st) {
          _backend = null;
          Error.throwWithStackTrace(e, st);
        },
      );

  Future<WebDavBackend> _build() async {
    final stored = await credentials();
    if (stored == null) throw const BackendUnauthorized('no credentials');
    final WebDavCredentials c;
    try {
      c = WebDavCredentials.fromJson(stored);
    } on FormatException catch (e) {
      debugPrint('[FilesSource] Unreadable WebDAV credentials: $e');
      throw const BackendUnauthorized('unreadable credentials');
    }
    return WebDavBackend(
        base: base, user: c.user, password: c.password, client: _client);
  }

  @override
  Future<List<FileEntry>> list(String dir) => _call((b) => b.list(dir));

  @override
  Future<FileEntry?> stat(String path) => _call((b) => b.stat(path));

  @override
  Future<PlayableFile> playable(String path) => _call((b) => b.playable(path));

  @override
  Future<void> probe() => _call((b) => b.probe());
}
