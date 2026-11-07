/// Wiring for files libraries: the index box, one index per account, the
/// backends, and building a [FilesMediaSource] for a stored [Source].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce/hive.dart';

import '../../cache/watcher_registry.dart' show invalidatorProvider;
import '../../playback/playback_progress_store.dart';
import '../connection/connection_refresh_bus.dart';
import '../source.dart';
import '../sources_providers.dart' show sourceSecretsProvider;
import 'backend/file_system_backend.dart';
import 'backend/local_path_backend.dart';
import 'backend/webdav_backend.dart';
import 'files_account.dart';
import 'files_media_source.dart';
import 'files_scan_controller.dart';
import 'index/file_library_index.dart';
import 'match/file_matcher.dart';
import 'media_names.dart';

/// Opens the boxes a files source reads synchronously while it builds: its
/// index and the playback progress store. Called at startup after
/// `initAppHive()`; Hive hands back an already-open box.
Future<void> openFilesLibraryBoxes() async {
  await Hive.openBox<Map<dynamic, dynamic>>(FileLibraryIndex.boxName);
  await Hive.openBox<Map<dynamic, dynamic>>(HivePlaybackProgressStore.boxName);
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

final relayTmdbProvider = Provider<RelayTmdb>((ref) => RelayTmdb());

/// Overridable so tests can tell the time a scan is due.
final filesClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

typedef FilesBackendBuilder = FileSystemBackend Function(
    Ref ref, Source source);

/// How a files source reaches its files. Tests override it with a fake.
final filesBackendBuilderProvider =
    Provider<FilesBackendBuilder>((_) => defaultFilesBackend);

/// Folders on this device have many roots and no single one to probe, so the
/// local backend has none; a root that is gone shows up when it is scanned.
/// A WebDAV share reads its credentials on first use.
FileSystemBackend defaultFilesBackend(Ref ref, Source source) {
  if (source.account.id == kFilesLocalAccountId ||
      source.server.connections.isEmpty) {
    return LocalPathBackend();
  }
  final secrets = ref.read(sourceSecretsProvider);
  return _LazyWebDavBackend(
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
FilesMediaSource buildFilesSource(
  Ref ref,
  Source source, {
  required void Function() onReauthNeeded,
}) {
  final index = ref.read(filesIndexProvider(source.account.id));
  final progress = ref.read(filesProgressStoreProvider);
  final tmdb = ref.read(relayTmdbProvider);
  final invalidator = ref.read(invalidatorProvider);
  final matcher = FileMatcher(
    tmdb: tmdb,
    names: ref.read(mediaNamesProvider),
    index: index,
    progress: progress,
    sourceId: source.id,
    onGroupLanded: () =>
        invalidator.invalidate(FilesMediaSource.groupLandedTargets(source.id)),
  );
  late final FilesMediaSource media;
  final events = ref
      .read(connectionRefreshBusProvider)
      .events
      .listen((_) => unawaited(media.probe()));
  media = FilesMediaSource(
    source: source,
    backend: ref.read(filesBackendBuilderProvider)(ref, source),
    index: index,
    progress: progress,
    matcher: matcher,
    tmdb: tmdb,
    onReauthNeeded: onReauthNeeded,
    invalidate: invalidator.invalidate,
    onDispose: events.cancel,
  );
  unawaited(media.probe());
  if (filesRescanDue(index.lastScanAt(), ref.read(filesClockProvider)())) {
    // After this build: the scan reads the source back from its provider.
    scheduleMicrotask(() {
      if (!ref.mounted) return;
      unawaited(ref.read(filesScanProvider(source.id).notifier).rescan());
    });
  }
  return media;
}

/// A [WebDavBackend] built on first use from the stored credentials. A
/// missing or unreadable credential is a refused one.
class _LazyWebDavBackend implements FileSystemBackend {
  _LazyWebDavBackend({required this.base, required this.credentials});

  final Uri base;
  final Future<String?> Function() credentials;
  Future<WebDavBackend>? _backend;

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
    return WebDavBackend(base: base, user: c.user, password: c.password);
  }

  @override
  Future<List<FileEntry>> list(String dir) async =>
      (await _resolve()).list(dir);

  @override
  Future<FileEntry?> stat(String path) async => (await _resolve()).stat(path);

  @override
  Future<PlayableFile> playable(String path) async =>
      (await _resolve()).playable(path);

  @override
  Future<void> probe() async => (await _resolve()).probe();
}
