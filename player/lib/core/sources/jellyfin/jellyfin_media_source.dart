/// A Jellyfin server, as one user sees it, as a [MediaSource].
library;

import 'package:flutter/foundation.dart';

import '../../../domain/models/download_option.dart';
import '../../../domain/models/download_plan.dart';
import '../../../domain/models/media_segment.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../original_download.dart';
import '../source.dart';
import 'jellyfin_client.dart';
import 'jellyfin_mapping.dart';
import 'jellyfin_playback_info.dart';

class JellyfinMediaSource extends MediaSource
    implements
        WatchedState,
        Searchable,
        ContinueWatching,
        Similar,
        Favorites,
        NextUp,
        RecentlyAdded,
        SkipSegments,
        Downloadable,
        ProgressSync {
  JellyfinMediaSource({
    required this.source,
    required this.client,
    void Function()? onDispose,
  }) : _onDispose = onDispose;

  @override
  final Source source;
  final JellyfinClient client;
  final void Function()? _onDispose;

  static const _childPage = 200;
  static const _rowLimit = 20;
  static const _rowImages = {'EnableImageTypes': 'Primary,Backdrop,Thumb'};

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.similar,
        SourceCapability.favorites,
        SourceCapability.nextUp,
        SourceCapability.recentlyAdded,
        SourceCapability.skipSegments,
        SourceCapability.downloadable,
        SourceCapability.progressSync,
      };

  /// `send` throws a `SourceException` on a transport failure or any non-2xx
  /// answer, so a refused push leaves the local record unsynced.
  @override
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  }) async {
    await client.send('POST', '/Sessions/Playing/Stopped', body: {
      'ItemId': ref.externalId,
      'PositionTicks': positionSeconds * jellyfinTicksPerSecond,
    });
    if (watched) {
      await client.send('POST', '/UserPlayedItems/${ref.externalId}',
          query: {'userId': client.userId});
    }
  }

  @override
  SourceConnectionStatus get connection => client.connection.status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      client.connection.status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  Map<String, String> get _user => {'userId': client.userId};

  Future<JellyfinPlaybackInfo> playbackInfo(
    String itemId, {
    required String mediaSourceId,
    required Map<String, dynamic> deviceProfile,
  }) async =>
      JellyfinPlaybackInfo.fromJson(await client.post(
        '/Items/$itemId/PlaybackInfo',
        query: _user,
        body: {
          'DeviceProfile': deviceProfile,
          'MediaSourceId': mediaSourceId,
          'AutoOpenLiveStream': false,
          'EnableDirectPlay': true,
          'EnableDirectStream': true,
          'EnableTranscoding': true,
        },
      ));

  /// Library kinds by id, so paging does not re-fetch `/UserViews` on every
  /// page. Filled by [libraries].
  Map<String, LibraryKind>? _libraryKinds;

  @override
  Future<List<DownloadOption>> downloadOptions(ItemRef ref) =>
      originalOptions(this, ref);

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) => originalFile(
        this,
        ref,
        url: (v) => client.url('/Videos/${ref.externalId}/stream',
            {'static': 'true', 'mediaSourceId': v.id}),
        headers: client.headers,
      );

  @override
  Future<List<Library>> libraries() async {
    final body = await client.get('/UserViews', _user);
    final libraries = [
      for (final v in (body['Items'] as List? ?? const []))
        if (v is Map) jellyfinLibrary(id, v.cast<String, dynamic>()),
    ].whereType<Library>().toList();
    _libraryKinds = {for (final l in libraries) l.ref.id: l.kind};
    return libraries;
  }

  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async {
    if (_libraryKinds == null) await libraries();
    final kind = _libraryKinds?[library.id] ?? LibraryKind.videos;
    final sort =
        jellyfinSortOptions.where((o) => o.id == query.sortId).firstOrNull ??
            jellyfinSortOptions.first;
    final descending = query.descending ?? sort.descendingByDefault;
    final known = {for (final f in jellyfinFilterOptions) f.id};
    final filters = query.filterIds.where(known.contains).join(',');
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    final body = await client.get('/Items', {
      ..._user,
      'ParentId': library.id,
      'IncludeItemTypes': jellyfinItemTypes(kind),
      'Recursive': 'true',
      'StartIndex': '$start',
      'Limit': '${query.pageSize}',
      // Ties on date or rating fall back to the title.
      'SortBy': sort.id == 'SortName' ? 'SortName' : '${sort.id},SortName',
      'SortOrder': descending ? 'Descending' : 'Ascending',
      if (filters.isNotEmpty) 'Filters': filters,
      'Fields': 'ChildCount,$jellyfinSortFields',
      'EnableImageTypes': 'Primary,Backdrop,Thumb',
    });
    return _page(body, start);
  }

  Page<ItemSummary> _page(Map<String, dynamic> body, int start) {
    final items = [
      for (final m in (body['Items'] as List? ?? const []))
        if (m is Map) jellyfinSummary(id, m.cast<String, dynamic>()),
    ].whereType<ItemSummary>().toList();
    final total = body['TotalRecordCount'] as int?;
    final raw = (body['Items'] as List? ?? const []).length;
    final next = start + raw;
    return Page(
      items: items,
      total: total,
      nextCursor:
          total != null && next < total && raw > 0 ? Cursor('$next') : null,
    );
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    final body = await client.get('/Items/${ref.externalId}', _user);
    return jellyfinDetail(id, body) ?? (throw const SourceException.notFound());
  }

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    // `/Shows/{id}/Seasons` does not page: it always answers every season,
    // so a later cursor has nothing to add.
    if (parent.kind == ItemKind.show && start > 0) return const Page(items: []);
    final pageQuery = {'StartIndex': '$start', 'Limit': '$_childPage'};
    final body = switch (parent.kind) {
      ItemKind.show => await client.get('/Shows/${parent.externalId}/Seasons',
          {..._user, 'Fields': 'ChildCount'}),
      ItemKind.season => await client.get('/Items', {
          ..._user,
          'ParentId': parent.externalId,
          'IncludeItemTypes': 'Episode',
          'Fields': 'Overview',
          'SortBy': 'IndexNumber',
          ...pageQuery,
        }),
      ItemKind.folder => await client.get('/Items', {
          ..._user,
          'ParentId': parent.externalId,
          'SortBy': 'SortName',
          'Fields': 'ChildCount',
          ...pageQuery,
        }),
      ItemKind.movie || ItemKind.episode || ItemKind.video => null,
    };
    if (body == null) return const Page(items: []);
    if (parent.kind == ItemKind.show) {
      // Every season came back, so there is no next page.
      final page = _page(body, 0);
      return Page(items: page.items, total: page.total);
    }
    return _page(body, start);
  }

  @override
  Future<List<ItemSummary>> search(String query) async {
    final body = await client.get('/Items', {
      ..._user,
      'searchTerm': query,
      'Recursive': 'true',
      'IncludeItemTypes': 'Movie,Series,Episode,Video',
      'Limit': '50',
    });
    return _page(body, 0).items;
  }

  @override
  Future<List<ItemSummary>> similar(ItemRef ref) async {
    final body = await client.get('/Items/${ref.externalId}/Similar', {
      ..._user,
      'Limit': '$_rowLimit',
      ..._rowImages,
    });
    return _page(body, 0).items;
  }

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async {
    final body = await client.get('/Shows/NextUp', {
      ..._user,
      'seriesId': show.externalId,
      'Limit': '1',
      ..._rowImages,
    });
    return _page(body, 0).items.firstOrNull;
  }

  @override
  Future<void> setFavorite(ItemRef ref, bool favorite) => client.send(
        favorite ? 'POST' : 'DELETE',
        '/UserFavoriteItems/${ref.externalId}',
        query: _user,
      );

  @override
  Future<void> setWatched(ItemRef ref, bool watched) => client.send(
        watched ? 'POST' : 'DELETE',
        '/UserPlayedItems/${ref.externalId}',
        query: _user,
      );

  /// What the viewer has under way, then the next episode of each show they
  /// follow. Jellyfin keeps the two apart (Resume and Next Up); Plex's own
  /// row mixes them, so this does too. Resume entries come first because a
  /// Next Up episode carries no last-played date to interleave by. A Next Up
  /// episode is left out when its show already has a resume entry.
  @override
  Future<List<ItemSummary>> continueWatching() async {
    // Future.wait rethrows the first failure as-is, so the row sees the
    // SourceException rather than a wrapper.
    final bodies = await Future.wait([
      client.get('/UserItems/Resume', {
        ..._user,
        'MediaTypes': 'Video',
        'Limit': '$_rowLimit',
        ..._rowImages,
      }),
      client.get('/Shows/NextUp', {
        ..._user,
        'Limit': '$_rowLimit',
        'enableResumable': 'false',
        'enableRewatching': 'false',
        ..._rowImages,
      }),
    ]);
    final resume = _maps(bodies[0]);
    final resumingShows = {
      for (final m in resume)
        if (m['SeriesId'] case final String show) show,
    };
    return [
      ...resume,
      ..._maps(bodies[1]).where((m) => !resumingShows.contains(m['SeriesId'])),
    ]
        .map((m) => jellyfinSummary(id, m))
        .whereType<ItemSummary>()
        .take(_rowLimit)
        .toList();
  }

  /// Every library at once: with no `ParentId`, Jellyfin answers the newest
  /// items across the user's views, episodes grouped under their show.
  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    final items = await client.getList('/Items/Latest', {
      ..._user,
      'Limit': '$_rowLimit',
      'Fields': 'DateCreated,DateLastMediaAdded',
      ..._rowImages,
    });
    return items
        .map((m) => jellyfinSummary(id, m))
        .whereType<ItemSummary>()
        .take(_rowLimit)
        .toList();
  }

  /// Only a resume entry: Jellyfin has no way to dismiss a Next Up episode.
  @override
  bool canRemoveFromContinueWatching(ItemSummary item) =>
      item.userState.progressSeconds != null;

  /// Clears the resume point, which drops the entry from Resume. Played state
  /// is left as it was.
  @override
  Future<void> removeFromContinueWatching(ItemRef ref) => client.send(
        'POST',
        '/UserItems/${ref.externalId}/UserData',
        query: _user,
        body: {'PlaybackPositionTicks': 0},
      );

  static List<Map<String, dynamic>> _maps(Map<String, dynamic> body) => [
        for (final m in (body['Items'] as List? ?? const []))
          if (m is Map) m.cast<String, dynamic>(),
      ];

  /// 10.10 and later. Segments exist only where a provider plugin (Intro
  /// Skipper, for one) has run; core Jellyfin detects nothing itself.
  @override
  Future<List<MediaSegment>> skipSegments(ItemRef ref,
      {String? versionId}) async {
    try {
      return jellyfinSegments(
          await client.get('/MediaSegments/${ref.externalId}'));
    } on SourceException catch (e) {
      if (e.kind == SourceErrorKind.notFound) return const [];
      rethrow;
    }
  }

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async {
    final url = await client.url(art.path, {
      'fillWidth': '$width',
      'quality': '90',
    });
    return ArtworkRequest(
      url: url.toString(),
      headers: await client.headers(),
      cacheKey: '$id|${art.path}|$width',
    );
  }

  @override
  void dispose() {
    _onDispose?.call();
    client.connection.dispose();
  }
}
