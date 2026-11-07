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
    void Function()? onReauthNeeded,
    FilesInvalidate? invalidate,
    AppLocalizations Function()? l10n,
    void Function()? onDispose,
  })  : _progress = progress,
        _tmdb = tmdb,
        _onReauthNeeded = onReauthNeeded,
        _invalidate = invalidate,
        _l10n = l10n ?? currentAppLocalizations,
        _onDispose = onDispose;

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
  final void Function()? _onReauthNeeded;
  final FilesInvalidate? _invalidate;

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
      case ItemKind.movie || ItemKind.episode || ItemKind.video:
        ids.add(ref.externalId);
    }
    for (final i in ids) {
      await index.setWatched(i, watched);
      // A stored position would keep the item in Continue Watching, or keep
      // it watched past 90%, against the viewer's choice.
      await _progress.delete(progressKey(catalog.ref(ItemKind.movie, i)));
    }
    await _invalidate?.call(SourceRules.watchedChanged(id));
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

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) => true;

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {
    await _progress.delete(progressKey(ref));
    await _invalidate?.call(SourceRules.continueWatchingRemoved(id));
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
    final groups = catalog.groupsOfBase[parsed.base];
    if (groups == null || groups.isEmpty) {
      throw const SourceException.notFound();
    }
    final list = groups.toList()..sort();
    return (list, catalog.groupIsShow[list.first] ?? false);
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _onDispose?.call();
    _status.dispose();
  }
}
