/// A guest Mydia server browsed as a source.
library;

import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart' show DocumentNode;

import '../../../domain/models/media_segment.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../../../graphql/mutations/mark_watched.graphql.dart';
import '../../../graphql/mutations/remove_from_continue_watching.graphql.dart';
import '../../../graphql/mutations/toggle_favorite.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/guest_mydia.graphql.dart';
import '../../../graphql/queries/media_segments.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/search.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/queries/show_detail.graphql.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../source.dart';
import 'mydia_guest_client.dart';
import 'mydia_guest_mapping.dart';

const _sorts = [
  SortOption(id: 'TITLE', label: 'Title', shared: SharedSort.title),
  SortOption(
      id: 'ADDED_AT',
      label: 'Date added',
      descendingByDefault: true,
      shared: SharedSort.added),
  SortOption(id: 'YEAR', label: 'Year', descendingByDefault: true),
];

const _moviesLibrary = 'movies';
const _showsLibrary = 'shows';
const _searchLimit = 40;
const _rowLimit = 20;

/// Mydia sends artwork as absolute URLs that need no credentials.
ArtworkRequest? absoluteArtworkRequest(SourceId id, ArtworkRef art, int width) {
  final uri = Uri.tryParse(art.path);
  if (uri == null ||
      !(uri.scheme == 'http' || uri.scheme == 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return ArtworkRequest(
    url: art.path,
    headers: const {},
    cacheKey: '${id.value}|${art.path}|$width',
  );
}

class MydiaGuestSource extends MediaSource
    implements
        WatchedState,
        Searchable,
        ContinueWatching,
        RecentlyAdded,
        Favorites,
        NextUp,
        Similar,
        SkipSegments {
  MydiaGuestSource({
    required this.source,
    required this.client,
    void Function()? onDispose,
  }) : _onDispose = onDispose;

  @override
  final Source source;
  final MydiaGuestClient client;
  final void Function()? _onDispose;

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.recentlyAdded,
        SourceCapability.favorites,
        SourceCapability.nextUp,
        SourceCapability.similar,
        SourceCapability.skipSegments,
      };

  @override
  SourceConnectionStatus get connection => client.status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => client.status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  Future<Map<String, dynamic>> _q(
    DocumentNode doc, [
    Map<String, dynamic> vars = const {},
  ]) =>
      client.request(doc, vars);

  Future<Map<String, dynamic>> _payload(
    DocumentNode doc,
    Map<String, dynamic> vars,
    String field,
  ) async {
    final value = (await _q(doc, vars))[field];
    if (value is! Map<String, dynamic>) throw const SourceException.notFound();
    return value;
  }

  Future<Map<String, dynamic>> _show(String showId) =>
      _payload(documentNodeQueryTvShowDetail, {'id': showId}, 'tvShow');

  List<Map<String, dynamic>> _maps(Object? value) => [
        if (value is List)
          for (final v in value)
            if (v is Map<String, dynamic>) v,
      ];

  @override
  Future<List<Library>> libraries() async => [
        Library(
          ref: LibraryRef(sourceId: id, id: _moviesLibrary),
          title: 'Movies',
          kind: LibraryKind.movies,
          sortOptions: _sorts,
        ),
        Library(
          ref: LibraryRef(sourceId: id, id: _showsLibrary),
          title: 'TV Shows',
          kind: LibraryKind.shows,
          sortOptions: _sorts,
        ),
      ];

  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async {
    final isMovies = switch (library.id) {
      _moviesLibrary => true,
      _showsLibrary => false,
      _ => throw const SourceException.notFound(),
    };
    final sort =
        _sorts.where((o) => o.id == query.sortId).firstOrNull ?? _sorts.first;
    final descending = query.descending ?? sort.descendingByDefault;
    final data = await _q(
      isMovies ? documentNodeQueryGuestMovies : documentNodeQueryGuestTvShows,
      {
        'first': query.pageSize,
        'after': cursor?.value,
        'sort': {
          'field': sort.id,
          'direction': descending ? 'DESC' : 'ASC',
        },
      },
    );
    final conn = data[isMovies ? 'movies' : 'tvShows'];
    final map = conn is Map<String, dynamic> ? conn : const <String, dynamic>{};
    final items = [
      for (final edge in _maps(map['edges']))
        if (edge['node'] is Map<String, dynamic>)
          isMovies
              ? movieSummary(id, edge['node'] as Map<String, dynamic>)
              : showSummary(id, edge['node'] as Map<String, dynamic>),
    ];
    final info = map['pageInfo'];
    final pageInfo =
        info is Map<String, dynamic> ? info : const <String, dynamic>{};
    final end = pageInfo['endCursor'];
    return Page(
      items: items,
      total: map['totalCount'] as int?,
      nextCursor:
          pageInfo['hasNextPage'] == true && end is String ? Cursor(end) : null,
    );
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    switch (ref.kind) {
      case ItemKind.movie:
        return movieDetail(
            id,
            await _payload(
                documentNodeQueryMovieDetail, {'id': ref.externalId}, 'movie'));
      case ItemKind.show:
        return showDetail(id, await _show(ref.externalId));
      case ItemKind.season:
        final season = parseSeasonExternalId(ref.externalId);
        if (season == null) throw const SourceException.notFound();
        return seasonDetail(
            id, await _show(season.showId), season.seasonNumber);
      case ItemKind.episode:
        return episodeDetail(
            id,
            await _payload(documentNodeQueryEpisodeDetail,
                {'id': ref.externalId}, 'episode'));
      default:
        throw const SourceException.notFound();
    }
  }

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    switch (parent.kind) {
      case ItemKind.show:
        final show = await _show(parent.externalId);
        final poster = showPoster(show);
        final items = [
          for (final s in _maps(show['seasons']))
            seasonSummary(id, parent.externalId, s, poster: poster),
        ];
        return Page(items: items, total: items.length);
      case ItemKind.season:
        final season = parseSeasonExternalId(parent.externalId);
        if (season == null) throw const SourceException.notFound();
        final data = await _q(documentNodeQuerySeasonEpisodes, {
          'showId': season.showId,
          'seasonNumber': season.seasonNumber,
        });
        final items = [
          for (final e in _maps(data['seasonEpisodes']))
            episodeSummary(id, e, showTitle: null),
        ];
        return Page(items: items, total: items.length);
      default:
        return const Page(items: []);
    }
  }

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async =>
      absoluteArtworkRequest(id, art, width);

  @override
  Future<void> setWatched(ItemRef ref, bool watched) async {
    switch (ref.kind) {
      case ItemKind.movie:
        await _q(
            watched
                ? documentNodeMutationMarkMovieWatched
                : documentNodeMutationMarkMovieUnwatched,
            {'movieId': ref.externalId});
      case ItemKind.episode:
        await _q(
            watched
                ? documentNodeMutationMarkEpisodeWatched
                : documentNodeMutationMarkEpisodeUnwatched,
            {'episodeId': ref.externalId});
      case ItemKind.season:
        final season = parseSeasonExternalId(ref.externalId);
        if (season == null) throw const SourceException.notFound();
        await _markSeason(season.showId, season.seasonNumber, watched);
      case ItemKind.show:
        final show = await _show(ref.externalId);
        for (final s in _maps(show['seasons'])) {
          // A season the server sent without a number cannot be addressed.
          final number = s['seasonNumber'];
          if (number is! int) continue;
          await _markSeason(ref.externalId, number, watched);
        }
      default:
        throw const SourceException.unsupported();
    }
  }

  Future<void> _markSeason(String showId, int seasonNumber, bool watched) => _q(
      watched
          ? documentNodeMutationMarkSeasonWatched
          : documentNodeMutationMarkSeasonUnwatched,
      {'showId': showId, 'seasonNumber': seasonNumber});

  @override
  Future<List<ItemSummary>> search(String query) async {
    final data = await _q(
        documentNodeQuerySearch, {'query': query, 'first': _searchLimit});
    final search = data['search'];
    final sections = search is Map<String, dynamic>
        ? _maps(search['sections'])
        : const <Map<String, dynamic>>[];
    return [
      for (final section in sections)
        for (final r in _maps(section['results'])) searchResultSummary(id, r),
    ].whereType<ItemSummary>().toList();
  }

  @override
  Future<List<ItemSummary>> continueWatching() async {
    final data =
        await _q(documentNodeQueryGuestContinueWatching, {'first': _rowLimit});
    return [
      for (final c in _maps(data['continueWatching']))
        continueWatchingSummary(id, c),
    ].whereType<ItemSummary>().toList();
  }

  /// Its own request: an unknown field fails the whole document, so a guest
  /// predating segments must cost only the skip button.
  @override
  Future<List<MediaSegment>> skipSegments(ItemRef ref,
      {String? versionId}) async {
    final (doc, root) = switch (ref.kind) {
      ItemKind.movie => (documentNodeQueryMovieSegments, 'movie'),
      ItemKind.episode => (documentNodeQueryEpisodeSegments, 'episode'),
      _ => (null, ''),
    };
    if (doc == null) return const [];
    final Map<String, dynamic> data;
    try {
      data = await _q(doc, {'id': ref.externalId});
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.server) return const [];
      rethrow;
    }
    final files = _maps((data[root] as Map?)?['files']);
    final fileId = files.any((f) => f['id'] == versionId)
        ? versionId
        : files.firstOrNull?['id'];
    if (fileId is! String) return const [];
    return MediaSegment.forFile(data, root: root, fileId: fileId);
  }

  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    final data =
        await _q(documentNodeQueryGuestRecentlyAdded, {'first': _rowLimit});
    return [
      for (final r in _maps(data['recentlyAdded'])) recentlyAddedSummary(id, r),
    ].whereType<ItemSummary>().take(_rowLimit).toList();
  }

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) => true;

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {
    await _q(documentNodeMutationRemoveFromContinueWatching,
        {'mediaItemId': ref.externalId});
  }

  @override
  Future<void> setFavorite(ItemRef ref, bool favorite) {
    // The server only toggles, so the read-check-toggle runs one at a time
    // per item; two overlapping calls would both read the old state.
    final key = ref.externalId;
    final previous = _favoriteChains[key] ?? Future<void>.value();
    final run = previous.then((_) => _setFavorite(ref, favorite));
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _favoriteChains[key] = tail;
    tail.whenComplete(() {
      if (identical(_favoriteChains[key], tail)) _favoriteChains.remove(key);
    });
    return run;
  }

  final Map<String, Future<void>> _favoriteChains = {};

  Future<void> _setFavorite(ItemRef ref, bool favorite) async {
    final current = (await item(ref)).isFavorite;
    if (current == favorite) return;
    await _q(
        documentNodeMutationToggleFavorite, {'mediaItemId': ref.externalId});
  }

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async {
    final detail = await _show(show.externalId);
    final next = detail['nextUp'];
    final episode = next is Map<String, dynamic> ? next['episode'] : null;
    if (episode is! Map<String, dynamic>) return null;
    // The nested episode carries no show, so the show's own title stands in.
    return episodeSummary(id, episode, showTitle: detail['title'] as String?);
  }

  @override
  Future<List<ItemSummary>> similar(ItemRef ref) async {
    if (ref.kind != ItemKind.show) return const [];
    final show = await _show(ref.externalId);
    return [
      for (final r in _maps(show['similar'])) searchResultSummary(id, r),
    ]
        .whereType<ItemSummary>()
        .where((s) => s.ref != ref)
        .take(_rowLimit)
        .toList();
  }

  @override
  void dispose() {
    client.dispose();
    _onDispose?.call();
  }
}
