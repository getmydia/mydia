/// A Jellyfin server, as one user sees it, as a [MediaSource].
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../source.dart';
import 'jellyfin_client.dart';
import 'jellyfin_mapping.dart';
import 'jellyfin_playback_info.dart';

class JellyfinMediaSource extends MediaSource
    implements WatchedState, Searchable {
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

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
      };

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
      'Fields': 'ChildCount',
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
    final pageQuery = {'StartIndex': '$start', 'Limit': '$_childPage'};
    final body = switch (parent.kind) {
      ItemKind.show => await client.get('/Shows/${parent.externalId}/Seasons',
          {..._user, 'Fields': 'ChildCount'}),
      ItemKind.season => await client.get('/Items', {
          ..._user,
          'ParentId': parent.externalId,
          'IncludeItemTypes': 'Episode',
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
    // `/Shows/{id}/Seasons` does not page; it starts at 0 whatever was asked.
    return _page(body, parent.kind == ItemKind.show ? 0 : start);
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
  Future<void> setWatched(ItemRef ref, bool watched) => client.send(
        watched ? 'POST' : 'DELETE',
        '/UserPlayedItems/${ref.externalId}',
        query: _user,
      );

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
