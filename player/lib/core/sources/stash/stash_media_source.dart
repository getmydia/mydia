/// A Stash server as a [MediaSource]. Scenes are `ItemKind.video` in one
/// synthetic library.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../domain/models/download_option.dart';
import '../../../domain/models/download_plan.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/playback_sequence.dart';
import '../../../domain/sources/source_error.dart';
import '../capabilities.dart';
import '../media_source.dart';
import '../original_download.dart';
import '../source.dart';
import 'stash_client.dart';
import 'stash_documents.dart';
import 'stash_mapping.dart';

class StashMediaSource extends MediaSource
    implements
        WatchedState,
        Searchable,
        ContinueWatching,
        RecentlyAdded,
        Downloadable,
        ProgressSync,
        SceneSequence {
  /// [seed] fixes the `random` sort for the life of this instance, so paging
  /// and previous/next stepping see one stable shuffle. Tests inject it.
  StashMediaSource({
    required this.source,
    required this.client,
    this._onDispose,
    int? seed,
  }) : _seed = seed ?? Random().nextInt(1 << 31);

  final int _seed;

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
    SourceCapability.recentlyAdded,
    SourceCapability.downloadable,
    SourceCapability.progressSync,
  };

  /// `query` throws on a transport failure, a non-2xx answer and a GraphQL
  /// `errors` body, so a refused push leaves the local record unsynced.
  @override
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  }) async {
    final saved = await client.query(stashSaveActivity, {
      'id': ref.externalId,
      'resume_time': positionSeconds.toDouble(),
      'playDuration': 0.0,
    });
    _requireResult(saved, 'sceneSaveActivity');
    if (watched) {
      final played = await client.query(stashAddPlay, {'id': ref.externalId});
      _requireResult(played, 'sceneAddPlay');
    }
  }

  /// `query` answers `{}` for a 2xx with no `data`, which is not a result: the
  /// mutation may never have run, and the record must stay unsynced.
  /// `sceneSaveActivity` is a Boolean, so `false` is Stash declining the save;
  /// `sceneAddPlay` answers an object, which only has to be present.
  static void _requireResult(Map<String, dynamic> data, String key) {
    final result = data[key];
    if (result == null || result == false) {
      throw const SourceException.fault(SourceFault.stashNotConfirmed);
    }
  }

  @override
  SourceConnectionStatus get connection => client.connection.status.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable =>
      client.connection.status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  @override
  Future<List<DownloadOption>> downloadOptions(ItemRef ref) =>
      originalOptions(this, ref);

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) => originalFile(
    this,
    ref,
    url: (v) => client.url(v.streamPath ?? '/scene/${ref.externalId}/stream'),
    headers: client.headers,
  );

  @override
  Future<List<Library>> libraries() async => [
    Library(
      ref: LibraryRef(sourceId: id, id: stashScenesLibraryId),
      kind: LibraryKind.videos,
      scenes: true,
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
    final page = int.tryParse(cursor?.value ?? '') ?? 1;
    final data = await client.query(
      stashFindScenes,
      _findScenesVariables(
        PlaybackSequence(
          origin: SequenceOrigin.library,
          position: 0,
          sortId: query.sortId,
          descending: query.descending,
          filterIds: query.filterIds,
        ),
        page: page,
        perPage: query.pageSize,
      ),
    );
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

  /// The `findScenes` variables of one listing page. Every origin's filter and
  /// sort is defined here, so a scene's neighbours come from the same query
  /// that listed it.
  Map<String, dynamic> _findScenesVariables(
    PlaybackSequence seq, {
    required int page,
    required int perPage,
  }) {
    switch (seq.origin) {
      case SequenceOrigin.library:
        final sort =
            stashSortOptions.where((o) => o.id == seq.sortId).firstOrNull ??
            stashSortOptions.first;
        final descending = seq.descending ?? sort.descendingByDefault;
        return {
          'filter': {
            'page': page,
            'per_page': perPage,
            'sort': sort.id == 'random' ? 'random_$_seed' : sort.id,
            'direction': descending ? 'DESC' : 'ASC',
          },
          if (seq.filterIds.contains('unplayed'))
            'scene_filter': {
              'play_count': {'value': 0, 'modifier': 'EQUALS'},
            },
        };
      case SequenceOrigin.search:
        return {
          'filter': {'q': seq.query ?? '', 'per_page': perPage, 'page': page},
        };
      case SequenceOrigin.continueWatching:
        return {
          'filter': {
            'page': page,
            'per_page': perPage,
            'sort': 'last_played_at',
            'direction': 'DESC',
          },
          'scene_filter': {
            'resume_time': {'value': 0, 'modifier': 'GREATER_THAN'},
          },
        };
    }
  }

  static const _searchPageSize = 40;
  static const _shelfPageSize = 20;
  static const _libraryPageSize = 60;
  static const _maxScanPages = 5;

  /// Only the library is paged; the other origins are one page long.
  static int _sequencePageSize(SequenceOrigin origin) => switch (origin) {
    SequenceOrigin.library => _libraryPageSize,
    SequenceOrigin.search => _searchPageSize,
    SequenceOrigin.continueWatching => _shelfPageSize,
  };

  @override
  Future<SequenceNeighbours> neighbours(
    ItemRef ref,
    PlaybackSequence sequence,
  ) async {
    try {
      return await _neighbours(ref, sequence);
    } catch (e) {
      debugPrint('[StashMediaSource] Could not resolve neighbours: $e');
      return SequenceNeighbours.none;
    }
  }

  Future<SequenceNeighbours> _neighbours(
    ItemRef ref,
    PlaybackSequence seq,
  ) async {
    final perPage = _sequencePageSize(seq.origin);
    final lastPage = seq.origin == SequenceOrigin.library ? null : 1;
    final pages = <int, List<ItemSummary>>{};

    Future<List<ItemSummary>> pageItems(int page) async {
      if (pages[page] case final cached?) return cached;
      final data = await client.query(
        stashFindScenes,
        _findScenesVariables(seq, page: page, perPage: perPage),
      );
      return pages[page] = _page(data, page, perPage).items;
    }

    Future<ItemSummary?> itemAt(int index) async {
      if (index < 0) return null;
      final page = index ~/ perPage + 1;
      if (lastPage != null && page > lastPage) return null;
      final items = await pageItems(page);
      final offset = index % perPage;
      return offset < items.length ? items[offset] : null;
    }

    bool isCurrent(ItemSummary? item) =>
        item != null && item.ref.externalId == ref.externalId;

    Future<SequenceNeighbours> around(int index) async => SequenceNeighbours(
      previous: await _neighbourAt(itemAt, index - 1),
      next: await _neighbourAt(itemAt, index + 1),
    );

    final position = seq.position;
    // Fetch the pages covering position-1 .. position+1 up front.
    await itemAt(position - 1);
    final here = await itemAt(position);
    await itemAt(position + 1);
    if (isCurrent(here)) return around(position);

    int? indexIn(int page) {
      final i = pages[page]?.indexWhere(isCurrent) ?? -1;
      return i < 0 ? null : (page - 1) * perPage + i;
    }

    for (final page in pages.keys.toList()..sort()) {
      if (indexIn(page) case final found?) return around(found);
    }
    final scanTo = lastPage ?? _maxScanPages;
    for (var page = 1; page <= scanTo; page++) {
      final loaded = await pageItems(page);
      if (indexIn(page) case final found?) return around(found);
      if (loaded.length < perPage) break;
    }
    // The scene left the listing: whatever now sits at its place is next.
    return SequenceNeighbours(
      previous: await _neighbourAt(itemAt, position - 1),
      next: await _neighbourAt(itemAt, position),
    );
  }

  Future<SequenceNeighbour?> _neighbourAt(
    Future<ItemSummary?> Function(int) itemAt,
    int index,
  ) async {
    final item = await itemAt(index);
    // A scene with no file has nothing to play, and opening it would give a
    // player with no file id; it counts as no neighbour.
    if (item == null || item.defaultVersionId == null) return null;
    return SequenceNeighbour(item: item, position: index);
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

  Future<List<ItemSummary>> _shelf(
    SequenceOrigin origin, {
    String? query,
  }) async {
    final perPage = _sequencePageSize(origin);
    final data = await client.query(
      stashFindScenes,
      _findScenesVariables(
        PlaybackSequence(origin: origin, position: 0, query: query),
        page: 1,
        perPage: perPage,
      ),
    );
    return _page(data, 1, perPage).items;
  }

  @override
  Future<List<ItemSummary>> search(String query) =>
      _shelf(SequenceOrigin.search, query: query);

  @override
  Future<void> setWatched(ItemRef ref, bool watched) => client.query(
    watched ? stashAddPlay : stashResetPlayCount,
    {'id': ref.externalId},
  );

  @override
  Future<List<ItemSummary>> continueWatching() =>
      _shelf(SequenceOrigin.continueWatching);

  @override
  Future<List<ItemSummary>> recentlyAdded() async {
    final data = await client.query(stashFindScenes, {
      'filter': {
        'page': 1,
        'per_page': _shelfPageSize,
        'sort': 'created_at',
        'direction': 'DESC',
      },
    });
    return _page(data, 1, _shelfPageSize).items;
  }

  @override
  bool canRemoveFromContinueWatching(ItemSummary item) => true;

  /// A zero resume point drops the scene from [continueWatching]. Works on
  /// every Stash the source supports; `sceneResetActivity` needs 0.27.
  @override
  Future<void> removeFromContinueWatching(ItemRef ref) =>
      client.query(stashSaveActivity, {'id': ref.externalId, 'resume_time': 0});

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
