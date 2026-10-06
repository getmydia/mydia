/// A Mydia server browsed as a source.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gql/ast.dart' show DocumentNode;

import '../../../domain/models/download_option.dart';
import '../../../domain/models/download_plan.dart';
import '../../../domain/models/media_segment.dart';
import '../../../domain/models/media_stream.dart';
import '../../../domain/models/remote_device.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../../domain/sources/collection.dart';
import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../../../graphql/mutations/mark_watched.graphql.dart';
import '../../../graphql/mutations/register_device_node.graphql.dart';
import '../../../graphql/mutations/remove_from_continue_watching.graphql.dart';
import '../../../graphql/mutations/revoke_device.graphql.dart';
import '../../../graphql/mutations/toggle_favorite.graphql.dart';
import '../../../graphql/mutations/update_episode_progress.graphql.dart';
import '../../../graphql/mutations/update_movie_progress.graphql.dart';
import '../../../graphql/queries/devices_list.graphql.dart';
import '../../../graphql/queries/episode_detail.graphql.dart';
import '../../../graphql/queries/media_info.graphql.dart';
import '../../../graphql/queries/media_segments.graphql.dart';
import '../../../graphql/queries/movie_detail.graphql.dart';
import '../../../graphql/queries/mydia_queries.dart';
import '../../../graphql/queries/search.graphql.dart';
import '../../../graphql/queries/season_episodes.graphql.dart';
import '../../../graphql/queries/show_detail.graphql.dart';
import '../../p2p/local_proxy_service.dart';
import '../../p2p/media_route.dart';
import '../../remote/remote_roster.dart';
import '../../util/iso_date.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../source.dart';
import 'mydia_download_job_service.dart';
import 'mydia_client.dart';
import 'mydia_filters.dart';
import 'mydia_mapping.dart';
import 'mydia_media_info.dart';
import 'mydia_proxy.dart';
import 'mydia_transcode_job.dart';

const _moviesLibrary = mydiaMoviesLibrary;
const _showsLibrary = mydiaShowsLibrary;
const _searchLimit = 40;
const _rowLimit = 20;
const _collectionLimit = 50;

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

class MydiaSource extends MediaSource
    implements
        WatchedState,
        Searchable,
        ContinueWatching,
        RecentlyAdded,
        Favorites,
        NextUp,
        Similar,
        SkipSegments,
        Downloadable,
        ProgressSync,
        Collections,
        Calendar,
        SavedFilters,
        UnwatchedListing,
        FavoritesListing,
        MediaInfo,
        HomeHubs,
        RemoteTargets {
  MydiaSource({
    required this.source,
    required this.client,
    this.proxy,
    ValueListenable<SourceConnectionStatus>? status,
    void Function()? onDispose,
  })  : _status = status,
        _onDispose = onDispose;

  @override
  final Source source;
  final MydiaClient client;

  /// The shared local proxy, which carries a paired server's file bytes.
  /// Required to download from a paired server.
  final LocalProxyService Function()? proxy;

  /// Overrides [MydiaClient.status] when the connection is owned
  final ValueListenable<SourceConnectionStatus>? _status;
  final void Function()? _onDispose;

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.downloadable,
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.recentlyAdded,
        SourceCapability.favorites,
        SourceCapability.nextUp,
        SourceCapability.similar,
        SourceCapability.skipSegments,
        SourceCapability.progressSync,
        SourceCapability.collections,
        SourceCapability.calendar,
        SourceCapability.savedFilters,
        SourceCapability.unwatchedListing,
        SourceCapability.favoritesListing,
        SourceCapability.mediaInfo,
        SourceCapability.hubs,
        SourceCapability.remoteTargets,
      };

  /// `request` throws a `SourceException` on a transport failure, an auth
  /// failure it cannot refresh past and a GraphQL error, so a refused push
  /// leaves the local record unsynced.
  @override
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  }) async {
    final episode = ref.kind == ItemKind.episode;
    await client.request(
      episode
          ? documentNodeMutationUpdateEpisodeProgress
          : documentNodeMutationUpdateMovieProgress,
      {
        episode ? 'episodeId' : 'movieId': ref.externalId,
        'positionSeconds': positionSeconds,
        'durationSeconds': durationSeconds,
      },
    );
    if (watched) {
      await client.request(
        episode
            ? documentNodeMutationMarkEpisodeWatched
            : documentNodeMutationMarkMovieWatched,
        {episode ? 'episodeId' : 'movieId': ref.externalId},
      );
    }
  }

  @override
  SourceConnectionStatus get connection => statusListenable.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      _status ?? client.status;

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
          sortOptions: mydiaSortOptions,
          filterOptions: mydiaFilterOptions(LibraryKind.movies),
        ),
        Library(
          ref: LibraryRef(sourceId: id, id: _showsLibrary),
          title: 'TV Shows',
          kind: LibraryKind.shows,
          sortOptions: mydiaSortOptions,
          filterOptions: mydiaFilterOptions(LibraryKind.shows),
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
    final plan =
        mydiaBrowsePlan(movies: isMovies, query: query, cursor: cursor);
    if (plan.field == 'unwatched' || plan.field == 'favorites') {
      return _flatPage(plan.doc, plan.field, plan.vars, cursor,
          pageSize: query.pageSize);
    }
    final data = await _q(plan.doc, plan.vars);
    final conn = data[plan.field];
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

  /// The flat listings carry no connection, so a full page means there may be
  /// more, and the server's offset cursor names the last item already seen.
  Future<Page<ItemSummary>> _flatPage(
    DocumentNode doc,
    String field,
    Map<String, dynamic> vars,
    Cursor? cursor, {
    int pageSize = _rowLimit,
  }) async {
    final data = await _q(doc, {
      ...vars,
      'first': pageSize,
      'after': cursor?.value,
    });
    final raw = _maps(data[field]);
    return Page(
      items: [
        for (final m in raw)
          if (listingSummary(id, m) case final s?) s,
      ],
      nextCursor: raw.length == pageSize
          ? Cursor(offsetCursor(offsetOf(cursor) + pageSize))
          : null,
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
        await _q(documentNodeQueryMydiaContinueWatching, {'first': _rowLimit});
    return [
      for (final c in _maps(data['continueWatching']))
        continueWatchingSummary(id, c),
    ].whereType<ItemSummary>().toList();
  }

  /// Its own request: an unknown field fails the whole document, so a server
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

  late final MydiaDownloadJobService _jobs =
      MydiaDownloadJobService(request: client.request);

  @override
  Future<List<DownloadOption>> downloadOptions(ItemRef ref) async =>
      (await _jobs.getOptions(mydiaContentType(ref.kind), ref.externalId))
          .options;

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) async =>
      MydiaTranscodeJob(
        jobs: _jobs,
        contentType: mydiaContentType(ref.kind),
        id: ref.externalId,
        resolution: optionId,
        fileFor: _file,
      );

  bool _holdsProxy = false;

  LocalProxyService _proxy() =>
      proxy?.call() ??
      (throw StateError('A Mydia download needs a local proxy'));

  Future<DirectFile> _file(String jobId) async {
    final credentials = await client.credentials();
    if (credentials.isP2p) {
      // The hold lasts as long as the source: nothing observes a download
      // finishing, so [dispose] is where it is let go.
      _holdsProxy = true;
      final base = await mydiaProxyBase(_proxy(), credentials,
          owner: this, target: source.account.id);
      return DirectFile(
          url: MediaRoutes.download(base, jobId), extension: 'mp4');
    }
    final server = credentials.serverUrl?.replaceFirst(RegExp(r'/+$'), '');
    if (server == null) throw const SourceException.unreachable();
    return DirectFile(
      url: '$server/api/v1/download/job/$jobId/file',
      headers: {'Authorization': 'Bearer ${credentials.accessToken}'},
      extension: 'mp4',
    );
  }

  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    final data = await client.query(
      documentNodeQueryRecentlyAddedFull,
      fallback: documentNodeQueryRecentlyAddedFullLegacy,
      variables: const {'first': _rowLimit},
    );
    return [
      for (final r in _maps(data['recentlyAdded'])) listingSummary(id, r),
    ].whereType<ItemSummary>().take(_rowLimit).toList();
  }

  @override
  Future<List<SourceCollection>> collections() async {
    final data = await _q(documentNodeQueryCollections, {
      'first': _collectionLimit,
    });
    return [for (final c in _maps(data['collections'])) collectionOf(id, c)];
  }

  /// The server's `collectionItems` takes no `after`, so a collection is one
  /// page of up to 50 items, as the legacy screen showed.
  @override
  Future<Page<ItemSummary>> collectionItems(String collectionId,
      {Cursor? cursor}) async {
    if (cursor != null) return const Page(items: []);
    final data = await _q(documentNodeQueryCollectionItems,
        {'collectionId': collectionId, 'first': _collectionLimit});
    return Page(items: [
      for (final m in _maps(data['collectionItems']))
        if (listingSummary(id, m) case final s?) s,
    ]);
  }

  @override
  Future<List<ItemSummary>> calendar(DateTime start, DateTime end) async {
    final data = await _q(documentNodeQueryCalendar,
        {'start': isoDate(start), 'end': isoDate(end)});
    return [for (final e in _maps(data['calendar'])) calendarSummary(id, e)]
      ..sort((a, b) => (a.airDate ?? '').compareTo(b.airDate ?? ''));
  }

  @override
  SavedFilterQuery? filterQuery(MediaFilter filter) =>
      mydiaFilterQuery(id, filter);

  @override
  Future<Page<ItemSummary>> unwatched({Cursor? cursor}) => _flatPage(
      documentNodeQueryUnwatchedListing, 'unwatched', const {}, cursor);

  @override
  Future<Page<ItemSummary>> favorites({Cursor? cursor}) => _flatPage(
      documentNodeQueryFavoritesListing, 'favorites', const {}, cursor);

  @override
  Future<List<MediaFileInfo>> mediaInfo(ItemRef ref) async {
    final movie = ref.kind == ItemKind.movie;
    final data = await client.query(
      movie
          ? documentNodeQueryMovieMediaInfo
          : documentNodeQueryEpisodeMediaInfo,
      fallback: movie
          ? documentNodeQueryMovieMediaInfoLegacy
          : documentNodeQueryEpisodeMediaInfoLegacy,
      variables: {'id': ref.externalId},
    );
    final node = data[movie ? 'movie' : 'episode'];
    final files = node is Map<String, dynamic> ? node['files'] : null;
    return [for (final f in _maps(files)) mediaFileInfoFromJson(f)];
  }

  @override
  Future<List<Hub>> hubs() async {
    final data = await client.query(documentNodeQueryHomeRows,
        fallback: documentNodeQueryHomeRowsLegacy,
        variables: const {
          'recentlyAddedLimit': _rowLimit,
          'favoritesLimit': 10,
        });
    Hub row(String hubId, String title, Object? list) => Hub(
          id: hubId,
          title: title,
          items: [
            for (final m in _maps(list))
              if (listingSummary(id, m) case final s?) s,
          ],
        );
    return [
      row('recently-added', 'Recently Added', data['recentlyAdded']),
      row('favorites', 'Favorites', data['favorites']),
    ].where((h) => h.items.isNotEmpty).toList();
  }

  @override
  late final DeviceRoster roster = RemoteRoster(client: client);

  @override
  Future<bool> registerNode(String nodeId) async {
    try {
      if (nodeId.isEmpty) return false;
      final data = await client.request(
        documentNodeMutationRegisterDeviceNode,
        {'nodeId': nodeId},
      );
      final registered = data['registerDeviceNode'];
      return registered is Map && registered['nodeId'] == nodeId;
    } catch (error) {
      debugPrint('[MydiaSource] node registration failed: $error');
      return false;
    }
  }

  @override
  Future<List<RemoteDevice>> devices() async {
    final data = await _q(documentNodeQueryDevicesList);
    return [
      for (final d in _maps(data['devices']))
        RemoteDevice(
          id: d['id'] as String,
          deviceName: d['deviceName'] as String,
          platform: d['platform'] as String,
          lastSeenAt: d['lastSeenAt'] is String
              ? DateTime.tryParse(d['lastSeenAt'] as String)
              : null,
          isRevoked: d['isRevoked'] as bool? ?? false,
          createdAt: DateTime.parse(d['createdAt'] as String),
        ),
    ];
  }

  @override
  Future<bool> revokeDevice(String deviceId) async {
    final data = await _q(documentNodeMutationRevokeDevice, {'id': deviceId});
    final result = data['revokeDevice'];
    return result is Map && result['success'] == true;
  }

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) =>
      item.ref.kind != ItemKind.episode || item.showRef != null;

  /// [ref] is `ItemSummary.dismissRef`: the movie, or for an episode its
  /// show. The server refuses an episode id.
  @override
  Future<void> removeFromContinueWatching(ItemRef ref) async {
    if (ref.kind == ItemKind.episode) {
      throw const SourceException.unsupported();
    }
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
    // Only a p2p download ever took a hold, so a source that never
    // downloaded must not touch the shared proxy.
    if (_holdsProxy) unawaited(_proxy().release(this));
    client.dispose();
    _onDispose?.call();
  }
}
