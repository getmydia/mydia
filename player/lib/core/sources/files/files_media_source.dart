/// A files library (folders on this device or a WebDAV share) as a
/// [MediaSource]. Everything it lists comes from the local index; the
/// backend is only probed for the connection status.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/models/download_option.dart';
import '../../../domain/models/download_plan.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../../../l10n/current_l10n.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../cache/invalidation_target.dart';
import '../../p2p/peer_sync_records.dart';
import '../../p2p/peer_sync_store.dart';
import '../../playback/local_playback_progress.dart';
import '../../playback/playback_progress_store.dart';
import '../cache/source_keys.dart';
import '../cache/source_rules.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../original_download.dart';
import '../source.dart';
import 'backend/file_system_backend.dart';
import 'files_account.dart';
import 'files_ids.dart';
import 'files_queries.dart';
import 'index/file_library_index.dart';
import 'match/file_matcher.dart';
import 'media_names.dart';
import 'peer_files_sources.dart' show isPeerFilesSource;

typedef FilesInvalidate = Future<void> Function(
    Iterable<InvalidationTarget> targets);

/// TMDB image sizes, smallest first.
const _posterBuckets = [92, 154, 185, 342, 500, 780];

/// The smallest TMDB size at or above [width], else `original`.
String tmdbImageBucket(int width) {
  for (final b in _posterBuckets) {
    if (b >= width) return 'w$b';
  }
  return 'original';
}

class FilesMediaSource extends MediaSource
    implements
        WatchedState,
        Searchable,
        ContinueWatching,
        NextUp,
        RecentlyAdded,
        UnwatchedListing,
        MatchEditing,
        Downloadable {
  FilesMediaSource({
    required this.source,
    required this.backend,
    required this.index,
    required PlaybackProgressStore progress,
    required this.matcher,
    required RelayTmdb tmdb,
    PeerSyncStore? syncStore,
    void Function()? onSyncMutation,
    void Function()? onReauthNeeded,
    FilesInvalidate? invalidate,
    AppLocalizations Function()? l10n,
    void Function()? onDispose,
    String? syncAccountId,
    String Function()? peerDeviceName,
    void Function(String nodeId)? onPeerFilesChanged,
  })  : _peerDeviceName = peerDeviceName,
        _onPeerFilesChanged = onPeerFilesChanged,
        syncAccountId = syncAccountId ?? source.account.id,
        _progress = progress,
        _tmdb = tmdb,
        _syncStore = syncStore,
        _onSyncMutation = onSyncMutation,
        _onReauthNeeded = onReauthNeeded,
        _invalidate = invalidate,
        _l10n = l10n ?? currentAppLocalizations,
        _onDispose = onDispose {
    _activeSources.add(this);
  }

  static final _activeSources = <FilesMediaSource>{};

  /// The [FilesMediaSource] instances currently alive in the process.
  static Iterable<FilesMediaSource> get activeSources => _activeSources;

  static const _pageOf50 = 50;
  static const _rowLimit = 20;
  static const _searchLimit = 50;

  @override
  final Source source;
  final FileSystemBackend backend;
  final FileLibraryIndex index;
  final FileMatcher matcher;
  final PlaybackProgressStore _progress;
  final RelayTmdb _tmdb;
  final PeerSyncStore? _syncStore;
  final void Function()? _onSyncMutation;
  final void Function()? _onReauthNeeded;
  final FilesInvalidate? _invalidate;

  /// The lending device's name, for a library a paired player lends.
  final String Function()? _peerDeviceName;

  /// Asks for the lending host's manifest again, for a library a paired
  /// player lends.
  final void Function(String nodeId)? _onPeerFilesChanged;

  /// The account id sync keys carry. A library lent by a paired player
  /// keys on the host's id for it, so watch state lands on the host's
  /// records; every other library on its own.
  final String syncAccountId;

  PeerSyncStore? get syncStore => _syncStore;
  void Function()? get onSyncMutation => _onSyncMutation;

  String? syncKeyFor(ItemRef ref) => syncKeyForFilesItem(
        accountId: syncAccountId,
        externalId: ref.externalId,
        isEpisode: ref.kind == ItemKind.episode,
      );

  /// The store this source reads positions from; playback writes through it.
  PlaybackProgressStore get progressStore => _progress;

  /// Invalidates cache targets; a no-op when the source was built without one.
  Future<void> invalidateTargets(Iterable<InvalidationTarget> targets) async =>
      _invalidate?.call(targets);

  /// Refreshes the watched state of [ref] after its record changed. A record
  /// keyed by TMDB id is shared by every files source that holds the item,
  /// so each of them refreshes, as [setWatched] does.
  Future<void> invalidateWatchedFor(ItemRef ref) async {
    final syncKey = syncKeyFor(ref);
    if (_syncStore != null && syncKey != null && syncKey.startsWith('tmdb:')) {
      for (final s in _activeSources.toList()) {
        await s._invalidate?.call(SourceRules.watchedChanged(s.id));
      }
    } else {
      await _invalidate?.call(SourceRules.watchedChanged(id));
    }
  }

  final AppLocalizations Function() _l10n;
  final void Function()? _onDispose;

  final _status = ValueNotifier(SourceConnectionStatus.connecting);

  /// What a matched or rematched group changes: every listing and item of
  /// this source, and the libraries, since Folders comes and goes with
  /// unmatched files.
  static Set<InvalidationTarget> groupLandedTargets(SourceId id) => {
        for (final op in const [
          SourceOps.libraries,
          SourceOps.browse,
          SourceOps.item,
          SourceOps.children,
          SourceOps.continueWatching,
          SourceOps.recentlyAdded,
          SourceOps.unwatched,
        ])
          SourceKeys.family(id, op),
      };

  bool get _isNetworkShare => source.account.id != kFilesLocalAccountId;

  /// A library a paired player lends: its index is the host's copy, so
  /// nothing here may write to it, and its files are not downloaded.
  bool get _isPeer => isPeerFilesSource(source);

  bool get _downloadable => _isNetworkShare && !_isPeer;

  @override
  Set<SourceCapability> get capabilities => {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.nextUp,
        SourceCapability.recentlyAdded,
        SourceCapability.unwatchedListing,
        SourceCapability.matchEditing,
        SourceCapability.castable,
        if (_downloadable) SourceCapability.downloadable,
      };

  @override
  SourceConnectionStatus get connection => _status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _status;

  @override
  T? as<T extends Object>() {
    if (T == Downloadable && !_downloadable) return null;
    return this is T ? this as T : null;
  }

  /// Checks the backend: reachable is `local`; a refused credential or a
  /// lost folder permission flags the account for sign-in. Browsing reads the
  /// index whatever this says.
  Future<void> probe() async {
    try {
      await backend.probe();
      reportReachability(null);
    } on BackendFailure catch (e) {
      reportReachability(e);
    }
  }

  /// Applies what a probe or a scan learned: no [failure] is `local`; a
  /// refused credential or a lost permission flags the account for sign-in;
  /// any failure is `unreachable`.
  void reportReachability(BackendFailure? failure) {
    if (failure == null) {
      _setStatus(SourceConnectionStatus.local);
      return;
    }
    debugPrint('[FilesMediaSource] ${source.id} unreachable: $failure');
    if (failure is BackendUnauthorized || failure is BackendPermissionLost) {
      _onReauthNeeded?.call();
    }
    _setStatus(SourceConnectionStatus.unreachable);
  }

  void _setStatus(SourceConnectionStatus s) {
    if (!_disposed) _status.value = s;
  }

  FilesCatalog _catalog() => FilesCatalog.read(
        sourceId: id,
        index: index,
        progress: _progress,
        l10n: _l10n(),
        syncStore: _syncStore,
        accountId: syncAccountId,
      );

  IndexedFile? indexedFile(String fileKey) => index.files()[fileKey];

  LibraryRoot? rootFor(IndexedFile file) =>
      index.roots().where((r) => r.id == file.rootId).firstOrNull;

  Future<PlayableFile> playableForFileKey(String fileKey) async {
    final indexed = indexedFile(fileKey);
    final root = indexed == null ? null : rootFor(indexed);
    if (indexed == null || root == null) {
      throw const SourceException(
        SourceErrorKind.notFound,
        'Playable file not found',
      );
    }
    final path = filesBackendPath(root, indexed.path);
    if (!_isPeer) return backend.playable(path);
    try {
      return await backend.playable(path);
    } on BackendFailure catch (e) {
      throw _peerPlayFailure(e);
    }
  }

  /// What a failed play from a lent library tells the viewer, worded with
  /// the lending device's name. A missing file or a refused read also asks
  /// the client for that host's manifest, which is where a withdrawn file
  /// or a revoked grant becomes visible; the revocation itself comes from
  /// the roster, not from here.
  SourceException _peerPlayFailure(BackendFailure e) {
    final device = _peerDeviceName?.call() ?? '';
    final nodeId = source.server.machineIdentifier;
    void refresh() {
      if (nodeId != null) _onPeerFilesChanged?.call(nodeId);
    }

    switch (e) {
      case BackendNotFound():
        refresh();
        return SourceException.fault(SourceFault.peerFilesFileGone,
            detail: device);
      case BackendUnauthorized() || BackendPermissionLost():
        refresh();
        return const SourceException.unauthorized();
      case BackendUnreachable(status: 502):
        // The host answered, so it is connected: the status stays as is.
        return SourceException.fault(SourceFault.peerFilesShareDown,
            detail: device);
      case BackendUnreachable():
        reportReachability(e);
        return SourceException.fault(SourceFault.peerFilesHostUnreachable,
            detail: device);
    }
  }

  @override
  Future<List<Library>> libraries() async {
    final catalog = _catalog();
    return [
      for (final r in index.roots())
        Library(
          ref: LibraryRef(sourceId: id, id: r.id),
          title: r.title,
          kind: switch (r.kind) {
            FilesLibraryKind.movies => LibraryKind.movies,
            FilesLibraryKind.series => LibraryKind.shows,
            FilesLibraryKind.mixed => LibraryKind.videos,
          },
          sortOptions: filesSortOptions,
          filterOptions: filesFilterOptions,
        ),
      if (catalog.unmatched.isNotEmpty)
        Library(
          ref: LibraryRef(sourceId: id, id: kFilesFoldersLibraryId),
          title: _l10n().filesFoldersLibrary,
          kind: LibraryKind.videos,
          sortOptions: const [
            SortOption(
                id: 'title', name: SortName.title, shared: SharedSort.title),
          ],
        ),
    ];
  }

  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async {
    final catalog = _catalog();
    final List<ItemSummary> items;
    if (library.id == kFilesFoldersLibraryId) {
      final ids = catalog.rootsWithUnmatched;
      items = sortFilesItems([
        for (final r in index.roots())
          if (ids.contains(r.id)) catalog.folderSummary(r.id, ''),
      ], 'title');
    } else {
      if (!catalog.roots.containsKey(library.id)) {
        throw const SourceException.notFound();
      }
      var all = catalog.itemsUnder(library.id);
      if (query.filterIds.contains('unwatched')) {
        all = [
          for (final i in all)
            if (!i.userState.watched) i,
        ];
      }
      items = sortFilesItems(all, query.sortId, descending: query.descending);
    }
    return filesPage(items, query.pageSize, cursor: cursor);
  }

  /// What [ref], played from the file [fileKey], is called now. A scan that
  /// matches (or unmatches) the file's group while it plays moves its state
  /// to another id; progress saved after that must follow it there.
  ItemRef currentRef(ItemRef ref, String fileKey) {
    final parsed = index.files()[fileKey]?.parsed;
    if (parsed == null) return ref;
    final match = index.group(parsed.groupKey);
    ItemRef make(ItemKind kind, String externalId) =>
        ItemRef(sourceId: id, kind: kind, externalId: externalId);
    if (match != null && match.tmdbId == null) {
      return make(ItemKind.video, unmatchedFileId(fileKey));
    }
    final base = match?.tmdbId != null
        ? tmdbBase(match!.tmdbId!)
        : provisionalKey(parsed.groupKey);
    if (!(match?.isShow ?? parsed.isEpisode)) {
      return make(ItemKind.movie, movieId(base));
    }
    final was = parseFilesId(ref.externalId);
    final season = was?.season ?? parsed.season;
    final episode = was?.episode ?? parsed.episode;
    if (season == null || episode == null) return ref;
    return make(ItemKind.episode, episodeId(base, season, episode));
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async =>
      _catalog().detail(ref) ?? (throw const SourceException.notFound());

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    final items = _catalog().children(parent);
    if (items == null) throw const SourceException.notFound();
    return Page(items: items, total: items.length);
  }

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async {
    if (art.path.isEmpty) return null;
    final bucket = tmdbImageBucket(width);
    final path = art.path.startsWith('/') ? art.path : '/${art.path}';
    return ArtworkRequest(
      url: 'https://image.tmdb.org/t/p/$bucket$path',
      headers: const {},
      cacheKey: '$id|${art.path}|$bucket',
    );
  }

  // WatchedState

  @override
  Future<void> setWatched(ItemRef ref, bool watched) async {
    final catalog = _catalog();
    final ids = <String>[];
    switch (ref.kind) {
      case ItemKind.show || ItemKind.season:
        final p = parseFilesId(ref.externalId);
        final show = catalog.shows[p?.base];
        if (show == null) throw const SourceException.notFound();
        for (final (s, e) in show.episodeKeys) {
          if (ref.kind == ItemKind.season && s != p!.season) continue;
          ids.add(episodeId(show.base, s, e));
        }
      case ItemKind.folder:
        throw const SourceException.unsupported();
      case ItemKind.episode:
        // Its file may hold other episodes, whose state is read from it.
        ids
          ..add(ref.externalId)
          ..addAll(catalog.episodesSharingAFile(ref.externalId));
      case ItemKind.movie || ItemKind.video:
        ids.add(ref.externalId);
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    var hadTmdbChange = false;

    for (final i in ids) {
      final parsed = parseFilesId(i);
      final isEp = parsed?.season != null && parsed?.episode != null;
      final syncKey = syncKeyForFilesItem(
        accountId: syncAccountId,
        externalId: i,
        isEpisode: isEp,
      );
      if (_syncStore != null && syncKey != null) {
        await _syncStore.setWatched(syncKey, watched, nowMs: nowMs);
        if (syncKey.startsWith('tmdb:')) {
          hadTmdbChange = true;
        }
      }
      if (_syncStore == null || syncKey == null) {
        // A lent index is replaced by the host's next copy, so a flag
        // written here would vanish with it.
        if (!_isPeer) await index.setWatched(i, watched);
        await _progress.delete(progressKey(catalog.ref(ItemKind.movie, i)));
      } else {
        await _progress.delete(progressKey(catalog.ref(ItemKind.movie, i)));
      }
    }

    if (_syncStore != null) {
      _onSyncMutation?.call();
    }

    if (hadTmdbChange) {
      for (final s in _activeSources.toList()) {
        await s._invalidate?.call(SourceRules.watchedChanged(s.id));
      }
    } else {
      await _invalidate?.call(SourceRules.watchedChanged(id));
    }
  }

  // Searchable

  @override
  Future<List<ItemSummary>> search(String query) async {
    final wanted = filesIdentityKey(query);
    if (wanted.isEmpty) return const [];
    final catalog = _catalog();
    bool hit(ItemSummary i) => filesIdentityKey(i.title).contains(wanted);
    return [
      ...sortFilesItems(catalog.allTitles().where(hit).toList(), 'title'),
      ...sortFilesItems([
        for (final f in catalog.unmatched.values)
          if (hit(catalog.videoSummary(f))) catalog.videoSummary(f),
      ], 'title'),
    ].take(_searchLimit).toList();
  }

  // ContinueWatching

  @override
  Future<List<ItemSummary>> continueWatching() async {
    final catalog = _catalog();
    if (_syncStore == null) {
      final records = [
        for (final r in _progress.all())
          if (r.sourceId == id.value) r,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final out = <ItemSummary>[];
      for (final r in records) {
        final summary = catalog.playableSummary(r.mediaId);
        if (summary == null || summary.userState.progressSeconds == null) {
          continue;
        }
        out.add(summary);
        if (out.length == _rowLimit) break;
      }
      return out;
    }

    final candidates = <String, DateTime>{};

    for (final rec in _syncStore.allWatchRecords().values) {
      if (rec.key.startsWith('tmdb:movie:')) {
        final tmdbId = rec.key.substring('tmdb:movie:'.length);
        if (catalog.movies.containsKey(tmdbId)) {
          final mediaId = movieId(tmdbId);
          candidates[mediaId] =
              DateTime.fromMillisecondsSinceEpoch(rec.updatedAt);
        }
      } else if (rec.key.startsWith('tmdb:ep:')) {
        final parts = rec.key.split(':');
        if (parts.length == 5) {
          final tmdbId = parts[2];
          final season = int.tryParse(parts[3]);
          final episode = int.tryParse(parts[4]);
          if (season != null &&
              episode != null &&
              (catalog.shows[tmdbId]?.seasons[season]?.containsKey(episode) ??
                  false)) {
            final mediaId = episodeId(tmdbId, season, episode);
            candidates[mediaId] =
                DateTime.fromMillisecondsSinceEpoch(rec.updatedAt);
          }
        }
      } else if (rec.key.startsWith('file:')) {
        final parts = rec.key.split(':');
        if (parts.length == 3 && parts[1] == syncAccountId) {
          final fileKey = parts[2];
          if (catalog.unmatched.containsKey(fileKey)) {
            final mediaId = unmatchedFileId(fileKey);
            candidates[mediaId] =
                DateTime.fromMillisecondsSinceEpoch(rec.updatedAt);
          }
        }
      }
    }

    for (final r in _progress.all()) {
      if (r.sourceId == id.value) {
        final parsed = parseFilesId(r.mediaId);
        if (parsed != null && parsed.isProvisional) {
          candidates[r.mediaId] = r.updatedAt;
        }
      }
    }

    final sortedMediaIds = candidates.keys.toList()
      ..sort((a, b) => candidates[b]!.compareTo(candidates[a]!));

    final out = <ItemSummary>[];
    for (final mediaId in sortedMediaIds) {
      final summary = catalog.playableSummary(mediaId);
      if (summary == null || summary.userState.progressSeconds == null) {
        continue;
      }
      out.add(summary);
      if (out.length == _rowLimit) break;
    }
    return out;
  }

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) => true;

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {
    final syncKey = syncKeyFor(ref);
    if (_syncStore != null && syncKey != null) {
      await _syncStore.removeFromContinueWatching(
        syncKey,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      _onSyncMutation?.call();
    }
    await _progress.delete(progressKey(ref));
    if (_syncStore != null && syncKey != null && syncKey.startsWith('tmdb:')) {
      for (final s in _activeSources.toList()) {
        await s._invalidate?.call(SourceRules.continueWatchingRemoved(s.id));
      }
    } else {
      await _invalidate?.call(SourceRules.continueWatchingRemoved(id));
    }
  }

  // NextUp

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async {
    final catalog = _catalog();
    final s = catalog.shows[show.externalId];
    return s == null ? null : catalog.nextUp(s);
  }

  // RecentlyAdded

  @override
  Future<List<ItemSummary>> recentlyAdded() async =>
      sortFilesItems(_catalog().allTitles(), 'added', descending: true)
          .take(_rowLimit)
          .toList();

  // UnwatchedListing

  @override
  Future<Page<ItemSummary>> unwatched({Cursor? cursor}) async {
    final items = [
      for (final i in _catalog().allTitles())
        if (!i.userState.watched) i,
    ];
    return filesPage(
        sortFilesItems(items, 'added', descending: true), _pageOf50,
        cursor: cursor);
  }

  // MatchEditing

  @override
  bool canEditMatch(ItemRef ref) {
    // A match pin is written into the index, which for a lent library is
    // the host's; the host fixes its own matches.
    if (_isPeer) return false;
    if (ref.kind != ItemKind.movie &&
        ref.kind != ItemKind.show &&
        ref.kind != ItemKind.video) {
      return false;
    }
    try {
      _groupsOf(ref, _catalog());
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<TmdbCandidate>> searchMatches(
    ItemRef ref,
    String query, {
    int? year,
  }) async {
    final (_, isShow) = _groupsOf(ref, _catalog());
    try {
      return isShow
          ? await _tmdb.searchShows(query, year: year)
          : await _tmdb.searchMovies(query, year: year);
    } on RelayUnavailable catch (e) {
      debugPrint('[FilesMediaSource] Match search failed: $e');
      throw const SourceException.unreachable();
    }
  }

  @override
  Future<void> setMatch(ItemRef ref, TmdbCandidate? choice) async {
    if (_isPeer) throw const SourceException.unsupported();
    final (groups, isShow) = _groupsOf(ref, _catalog());
    try {
      for (final g in groups) {
        await matcher.pin(g, isShow: isShow, tmdbId: choice?.id);
      }
    } on RelayUnavailable catch (e) {
      debugPrint('[FilesMediaSource] Pinning a match failed: $e');
      throw const SourceException.unreachable();
    }
    await _invalidate?.call(groupLandedTargets(id));
  }

  /// The group keys [ref] stands for, and whether they are shows. A loose
  /// file whose name could not be read has no group and cannot be matched.
  (List<String>, bool) _groupsOf(ItemRef ref, FilesCatalog catalog) {
    final parsed = parseFilesId(ref.externalId);
    if (parsed == null) throw ArgumentError.value(ref, 'ref', 'not matchable');
    if (parsed.fileKey case final key?) {
      final group = catalog.unmatched[key]?.parsed?.groupKey;
      if (group == null) {
        throw ArgumentError.value(ref, 'ref', 'file name could not be read');
      }
      return ([group], catalog.groupIsShow[group] ?? false);
    }
    final isShow = ref.kind == ItemKind.show;
    final groups = catalog.groupsOfBase[(isShow, parsed.base!)];
    if (groups == null || groups.isEmpty) {
      throw const SourceException.notFound();
    }
    return (groups.toList()..sort(), isShow);
  }

  String? backendPathOfFileKey(String fileKey) {
    final IndexedFile? file = index.files()[fileKey];
    if (file == null) return null;
    final root = index.roots().where((r) => r.id == file.rootId).firstOrNull;
    return root == null ? null : filesBackendPath(root, file.path);
  }

  // Downloadable

  @override
  Future<List<DownloadOption>> downloadOptions(
    ItemRef item, [
    String? versionId,
  ]) async {
    final detail = await this.item(item);
    final version = versionId != null
        ? (detail.versions.where((v) => v.id == versionId).firstOrNull ??
            detail.versions.firstOrNull)
        : downloadVersion(detail);
    return version == null ? const [] : [originalOption(version)];
  }

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) async {
    final detail = await item(ref);
    final version = downloadVersion(detail) ??
        (throw const SourceException.unsupportedFault(
            SourceFault.noFileToDownload));
    return _resolveVersion(version);
  }

  Future<PreparedDownloadFile> prepareDownload(
    ItemRef item,
    String versionId,
    DownloadOption option,
  ) async {
    final detail = await this.item(item);
    final version =
        detail.versions.where((v) => v.id == versionId).firstOrNull ??
            detail.versions.firstOrNull;
    if (version == null) {
      throw const SourceException.unsupportedFault(
          SourceFault.noFileToDownload);
    }
    return _resolveVersion(version);
  }

  Future<PreparedDownloadFile> _resolveVersion(MediaVersion version) async {
    final path = backendPathOfFileKey(version.id);
    if (path == null) {
      throw const SourceException.unsupportedFault(
          SourceFault.noFileToDownload);
    }
    try {
      final stat = await backend.stat(path);
      if (stat == null) throw const SourceException.notFound();
      final playable = await backend.playable(path);
      reportReachability(null);
      return originalFileForVersion(
        version,
        url: playable.url,
        headers: playable.headers,
      );
    } on BackendFailure catch (e) {
      reportReachability(e);
      throw switch (e) {
        BackendUnauthorized() ||
        BackendPermissionLost() =>
          const SourceException.unauthorized(),
        BackendNotFound() => const SourceException.notFound(),
        BackendUnreachable() => const SourceException.unreachable(),
      };
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _activeSources.remove(this);
    _onDispose?.call();
    _status.dispose();
  }
}

extension FilesDownloadableExtension on Downloadable {
  Future<PreparedDownloadFile> prepareDownload(
    ItemRef item,
    String versionId,
    DownloadOption option,
  ) {
    if (this is FilesMediaSource) {
      return (this as FilesMediaSource)
          .prepareDownload(item, versionId, option);
    }
    throw UnsupportedError('Only supported on FilesMediaSource');
  }
}
