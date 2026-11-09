/// A files library (folders on this device or a WebDAV share) as a
/// [MediaSource]. Everything it lists comes from the local index; the
/// backend is only probed for the connection status.
library;

import 'package:flutter/foundation.dart';

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
import '../source.dart';
import 'backend/file_system_backend.dart';
import 'files_ids.dart';
import 'files_queries.dart';
import 'index/file_library_index.dart';
import 'match/file_matcher.dart';
import 'media_names.dart';

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
        MatchEditing {
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
  })  : _progress = progress,
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

  PeerSyncStore? get syncStore => _syncStore;
  void Function()? get onSyncMutation => _onSyncMutation;

  String? syncKeyFor(ItemRef ref) => syncKeyForFilesItem(
        accountId: source.account.id,
        externalId: ref.externalId,
        isEpisode: ref.kind == ItemKind.episode,
      );

  /// The store this source reads positions from; playback writes through it.
  PlaybackProgressStore get progressStore => _progress;

  /// Invalidates cache targets; a no-op when the source was built without one.
  Future<void> invalidateTargets(Iterable<InvalidationTarget> targets) async =>
      _invalidate?.call(targets);
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

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.nextUp,
        SourceCapability.recentlyAdded,
        SourceCapability.unwatchedListing,
        SourceCapability.matchEditing,
      };

  @override
  SourceConnectionStatus get connection => _status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

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
        accountId: source.account.id,
      );

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
        accountId: source.account.id,
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
        await index.setWatched(i, watched);
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
        if (parts.length == 3 && parts[1] == source.account.id) {
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

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _activeSources.remove(this);
    _onDispose?.call();
    _status.dispose();
  }
}
