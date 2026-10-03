/// A Plex server as a [MediaSource].
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../source.dart';
import 'plex_mapping.dart';
import 'plex_server_client.dart';

class PlexMediaSource extends MediaSource
    implements WatchedState, Searchable, ContinueWatching, HomeHubs {
  PlexMediaSource({
    required this.source,
    required this.client,
    void Function()? onDispose,
  }) : _onDispose = onDispose;

  @override
  final Source source;
  final PlexServerClient client;
  final void Function()? _onDispose;

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.hubs,
      };

  @override
  SourceConnectionStatus get connection => client.connection.status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      client.connection.status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  @override
  Future<List<Library>> libraries() async {
    final body = await client.container('/library/sections');
    final libraries = [
      for (final d in (body['Directory'] as List? ?? const []))
        if (d is Map) plexLibrary(id, d.cast<String, dynamic>()),
    ].whereType<Library>().toList();
    _sectionKinds = {for (final l in libraries) l.ref.id: l.kind};
    return libraries;
  }

  /// Section kinds by section id, so paging a library does not re-fetch
  /// `/library/sections` on every page. Filled by [libraries].
  Map<String, LibraryKind>? _sectionKinds;

  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async {
    if (_sectionKinds == null) await libraries();
    final kind = _sectionKinds?[library.id];
    final sort =
        plexSortOptions.where((o) => o.id == query.sortId).firstOrNull ??
            plexSortOptions.first;
    final descending = query.descending ?? sort.descendingByDefault;
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    final body = await client.container('/library/sections/${library.id}/all', {
      'type': kind == LibraryKind.shows ? '2' : '1',
      'sort': '${sort.id}:${descending ? 'desc' : 'asc'}',
      if (query.filterIds.contains('unwatched')) 'unwatched': '1',
      'X-Plex-Container-Start': '$start',
      'X-Plex-Container-Size': '${query.pageSize}',
    });
    return _page(body, start);
  }

  Page<ItemSummary> _page(Map<String, dynamic> body, int start) {
    final items = [
      for (final m in (body['Metadata'] as List? ?? const []))
        if (m is Map) plexSummary(id, m.cast<String, dynamic>()),
    ].whereType<ItemSummary>().toList();
    final total = body['totalSize'] as int?;
    final size = body['size'] as int? ?? items.length;
    final next = start + size;
    return Page(
      items: items,
      total: total,
      nextCursor:
          total != null && next < total && size > 0 ? Cursor('$next') : null,
    );
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    final body = await client.container('/library/metadata/${ref.externalId}');
    final list = body['Metadata'] as List? ?? const [];
    if (list.isEmpty || list.first is! Map) {
      throw const SourceException.notFound();
    }
    return plexDetail(id, (list.first as Map).cast<String, dynamic>());
  }

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    final start = int.tryParse(cursor?.value ?? '') ?? 0;
    final body = await client.container(
      '/library/metadata/${parent.externalId}/children',
      {
        'X-Plex-Container-Start': '$start',
        'X-Plex-Container-Size': '200',
      },
    );
    return _page(body, start);
  }

  @override
  Future<List<ItemSummary>> search(String query) async {
    final body = await client.container('/hubs/search', {
      'query': query,
      'limit': '20',
    });
    return [
      for (final hub in (body['Hub'] as List? ?? const []))
        if (hub is Map)
          for (final m in (hub['Metadata'] as List? ?? const []))
            if (m is Map) plexSummary(id, m.cast<String, dynamic>()),
    ].whereType<ItemSummary>().toList();
  }

  @override
  Future<void> setWatched(ItemRef ref, bool watched) => client.ping(
        watched ? '/:/scrobble' : '/:/unscrobble',
        {
          'identifier': 'com.plexapp.plugins.library',
          'key': ref.externalId,
        },
      );

  static const _rowLimit = 20;

  @override
  Future<List<ItemSummary>> continueWatching() async {
    final body = await client.container('/hubs/continueWatching/items', {
      'X-Plex-Container-Start': '0',
      'X-Plex-Container-Size': '$_rowLimit',
    });
    return [
      for (final m in (body['Metadata'] as List? ?? const []))
        if (m is Map) plexSummary(id, m.cast<String, dynamic>()),
    ].whereType<ItemSummary>().take(_rowLimit).toList();
  }

  @override
  Future<void> removeFromContinueWatching(ItemRef ref) => client.put(
        '/actions/removeFromContinueWatching',
        {'ratingKey': ref.externalId},
      );

  @override
  Future<List<Hub>> hubs() async {
    if (_sectionKinds == null) await libraries();
    final libraryIds = _sectionKinds?.keys.toSet() ?? const <String>{};
    final body = await client.container('/hubs', {'count': '$_rowLimit'});
    final seen = <String>{};
    return [
      for (final h in (body['Hub'] as List? ?? const []))
        if (h is Map)
          if (plexHub(id, h.cast<String, dynamic>(), libraryIds: libraryIds)
              case final hub? when seen.add(hub.id))
            Hub(
              id: hub.id,
              title: hub.title,
              items: hub.items.take(_rowLimit).toList(),
              library: hub.library,
            ),
    ];
  }

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async {
    final url = await client.url('/photo/:/transcode', {
      'url': art.path,
      'width': '$width',
      'height': '$width',
      'minSize': '1',
      'upscale': '1',
    });
    final headers = await client.headers();
    return ArtworkRequest(
      url: url.toString(),
      headers: {
        if (headers['X-Plex-Token'] case final token?) 'X-Plex-Token': token,
      },
      cacheKey: '$id|${art.path}|$width',
    );
  }

  @override
  void dispose() {
    _onDispose?.call();
    client.connection.dispose();
  }
}
