/// A Stash server as a [MediaSource]. Scenes are `ItemKind.video` in one
/// synthetic library.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../source.dart';
import 'stash_client.dart';
import 'stash_documents.dart';
import 'stash_mapping.dart';

class StashMediaSource extends MediaSource
    implements WatchedState, Searchable, ContinueWatching {
  StashMediaSource({
    required this.source,
    required this.client,
    void Function()? onDispose,
  }) : _onDispose = onDispose;

  @override
  final Source source;
  final StashClient client;
  final void Function()? _onDispose;

  @override
  Set<SourceCapability> get capabilities => const {
        SourceCapability.progressReporting,
        SourceCapability.watchedState,
        SourceCapability.searchable,
        SourceCapability.continueWatching,
      };

  @override
  SourceConnectionStatus get connection => client.connection.status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      client.connection.status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  @override
  Future<List<Library>> libraries() async => [
        Library(
          ref: LibraryRef(sourceId: id, id: stashScenesLibraryId),
          title: 'Scenes',
          kind: LibraryKind.videos,
          sortOptions: stashSortOptions,
          filterOptions: stashFilterOptions,
        ),
      ];

  @override
  Future<Page<ItemSummary>> browse(
    LibraryRef library,
    BrowseQuery query, {
    Cursor? cursor,
  }) async {
    final sort =
        stashSortOptions.where((o) => o.id == query.sortId).firstOrNull ??
            stashSortOptions.first;
    final descending = query.descending ?? sort.descendingByDefault;
    final page = int.tryParse(cursor?.value ?? '') ?? 1;
    final data = await client.query(stashFindScenes, {
      'filter': {
        'page': page,
        'per_page': query.pageSize,
        'sort': sort.id,
        'direction': descending ? 'DESC' : 'ASC',
      },
      if (query.filterIds.contains('unplayed'))
        'scene_filter': {
          'play_count': {'value': 0, 'modifier': 'EQUALS'},
        },
    });
    return _page(data, page, query.pageSize);
  }

  Page<ItemSummary> _page(Map<String, dynamic> data, int page, int perPage) {
    final result =
        (data['findScenes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final scenes = result['scenes'] as List? ?? const [];
    final count = result['count'] as int? ?? scenes.length;
    return Page(
      items: [
        for (final s in scenes)
          if (s is Map) stashSummary(id, s.cast<String, dynamic>()),
      ],
      total: count,
      nextCursor: page * perPage < count ? Cursor('${page + 1}') : null,
    );
  }

  @override
  Future<ItemDetail> item(ItemRef ref) async {
    final data = await client.query(stashFindScene, {'id': ref.externalId});
    final scene = data['findScene'];
    if (scene is! Map) throw const SourceException.notFound();
    return stashDetail(id, scene.cast<String, dynamic>());
  }

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      const Page(items: []);

  @override
  Future<List<ItemSummary>> search(String query) async {
    final data = await client.query(stashFindScenes, {
      'filter': {'q': query, 'per_page': 40, 'page': 1},
    });
    return _page(data, 1, 40).items;
  }

  @override
  Future<void> setWatched(ItemRef ref, bool watched) => client.query(
        watched ? stashAddPlay : stashResetPlayCount,
        {'id': ref.externalId},
      );

  @override
  Future<List<ItemSummary>> continueWatching() async {
    final data = await client.query(stashFindScenes, {
      'filter': {
        'page': 1,
        'per_page': 20,
        'sort': 'last_played_at',
        'direction': 'DESC',
      },
      'scene_filter': {
        'resume_time': {'value': 0, 'modifier': 'GREATER_THAN'},
      },
    });
    return _page(data, 1, 20).items;
  }

  /// A zero resume point drops the scene from [continueWatching]. Works on
  /// every Stash the source supports; `sceneResetActivity` needs 0.27.
  @override
  Future<void> removeFromContinueWatching(ItemRef ref) => client.query(
        stashSaveActivity,
        {'id': ref.externalId, 'resume_time': 0},
      );

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async {
    final url = await client.url(art.path);
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
