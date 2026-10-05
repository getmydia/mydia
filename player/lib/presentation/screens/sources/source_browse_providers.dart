/// Per-screen state for the generic source screens, keyed by source. Screens
/// invalidate through `invalidateSourceItemWrites` after a write. Each leaf
/// provider is a `SourceWatcher`, so it paints from the cache and is refreshed
/// by `SourceRules`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderOrFamily;

import '../../../core/sources/cache/create_source_watcher.dart';
import '../../../core/sources/cache/source_codecs.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../detail/detail_links.dart';

MediaSource _require(Ref ref, SourceId id) =>
    ref.watch(mediaSourceProvider(id)) ??
    (throw const SourceException.notFound());

String sourceItemLocation(ItemRef ref) => detailKindOf(ref.kind) != null
    ? detailLocation(SourceTarget(ref))
    : '/s/${ref.sourceId.value}/item/${ref.kind.name}/${Uri.encodeComponent(ref.externalId)}';

String sourceLibraryLocation(LibraryRef ref) =>
    '/s/${ref.sourceId.value}/library/${Uri.encodeComponent(ref.id)}';

String sourcePlayerLocation(ItemDetail detail, MediaVersion version) {
  final ref = detail.summary.ref;
  return Uri(
    path: '/s/${ref.sourceId.value}/player/${ref.externalId}',
    queryParameters: {
      'kind': ref.kind.name,
      'fileId': version.id,
      'title': detail.summary.title,
    },
  ).toString();
}

final sourceLibrariesProvider =
    StreamProvider.autoDispose.family<List<Library>, SourceId>((ref, id) {
  final source = _require(ref, id);
  return createSourceWatcher(
    ref,
    key: SourceKeys.libraries(id),
    fetch: source.libraries,
    encode: encodeLibraries,
    decode: decodeLibraries,
  ).stream;
});

/// The home row for [library]: its "Recently added" sort when it has one.
final sourceLibraryPreviewProvider = StreamProvider.autoDispose
    .family<List<ItemSummary>, LibraryRef>((ref, library) async* {
  final source = _require(ref, library.sourceId);
  // selectAsync: a fresh libraries answer with the same sort must not
  // rebuild this row and fetch it twice.
  final sortId = await ref.watch(
    sourceLibrariesProvider(library.sourceId).selectAsync(
      (libraries) => libraries
          .where((l) => l.ref == library)
          .firstOrNull
          ?.sortOptions
          .where((o) => o.label == 'Recently added')
          .firstOrNull
          ?.id,
    ),
  );
  if (!ref.mounted) return;
  final query = BrowseQuery(sortId: sortId, pageSize: 20);
  yield* createSourceWatcher(
    ref,
    key: SourceKeys.browse(library, query),
    fetch: () => source.browse(library, query),
    encode: encodeSummaryPage,
    decode: decodeSummaryPage,
  ).stream.map((page) => page.items);
});

final sourceItemProvider =
    StreamProvider.autoDispose.family<ItemDetail, ItemRef>((ref, item) {
  final source = _require(ref, item.sourceId);
  return createSourceWatcher(
    ref,
    key: SourceKeys.item(item),
    fetch: () => source.item(item),
    encode: encodeDetail,
    decode: decodeDetail,
  ).stream;
});

/// Every child of [parent], following pages up to a sane cap.
final sourceChildrenProvider = StreamProvider.autoDispose
    .family<List<ItemSummary>, ItemRef>((ref, parent) {
  final source = _require(ref, parent.sourceId);
  return createSourceWatcher(
    ref,
    key: SourceKeys.children(parent),
    fetch: () => _allChildren(source, parent),
    encode: encodeSummaries,
    decode: decodeSummaries,
  ).stream;
});

Future<List<ItemSummary>> _allChildren(
    MediaSource source, ItemRef parent) async {
  final items = <ItemSummary>[];
  Cursor? cursor;
  for (var pages = 0; pages < 10; pages++) {
    final page = await source.children(parent, cursor: cursor);
    items.addAll(page.items);
    cursor = page.nextCursor;
    if (cursor == null) break;
  }
  return items;
}

class LibraryBrowseState {
  const LibraryBrowseState({
    required this.query,
    required this.items,
    this.nextCursor,
    this.total,
    this.loadingMore = false,
  });

  final BrowseQuery query;
  final List<ItemSummary> items;
  final Cursor? nextCursor;
  final int? total;
  final bool loadingMore;

  LibraryBrowseState copyWith({
    List<ItemSummary>? items,
    Cursor? nextCursor,
    bool clearCursor = false,
    bool? loadingMore,
  }) =>
      LibraryBrowseState(
        query: query,
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        total: total,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

class LibraryBrowseNotifier extends StreamNotifier<LibraryBrowseState> {
  LibraryBrowseNotifier(this.library);

  final LibraryRef library;
  BrowseQuery _query = const BrowseQuery();

  /// Bumped whenever the list is rebuilt for a (new) query, so a page that
  /// was requested for the old one is dropped when it lands.
  int _generation = 0;

  /// Set once the viewer asks for page 2. From then on the watcher declines
  /// automatic refetches and its page-1 answers are ignored: either would
  /// collapse the pages already on screen. Only page 1 is cached.
  bool _paged = false;

  @override
  Stream<LibraryBrowseState> build() {
    _generation++;
    _paged = false;
    final query = _query;
    final source = _require(ref, library.sourceId);
    final watcher = createSourceWatcher<Page<ItemSummary>>(
      ref,
      key: SourceKeys.browse(library, query),
      fetch: () => source.browse(library, query),
      encode: encodeSummaryPage,
      decode: decodeSummaryPage,
      canRefetch: () => !_paged,
    );
    return watcher.stream.where((_) => !_paged).map(
          (page) => LibraryBrowseState(
            query: query,
            items: page.items,
            nextCursor: page.nextCursor,
            total: page.total,
          ),
        );
  }

  Future<void> setQuery(BrowseQuery query) async {
    _query = query;
    _generation++;
    state = const AsyncLoading();
    ref.invalidateSelf();
    await future;
  }

  Future<void> loadMore() async {
    final current = switch (state) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final cursor = current?.nextCursor;
    if (current == null || cursor == null || current.loadingMore) return;
    final generation = _generation;
    _paged = true;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _require(ref, library.sourceId)
          .browse(library, current.query, cursor: cursor);
      if (!ref.mounted || generation != _generation) return;
      state = AsyncData(current.copyWith(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
      ));
    } catch (_) {
      // Any failure, not just a SourceException: loadingMore must not stick.
      if (ref.mounted && generation == _generation) {
        state = AsyncData(current.copyWith(loadingMore: false));
      }
    }
  }
}

final libraryBrowseProvider = StreamNotifierProvider.autoDispose
    .family<LibraryBrowseNotifier, LibraryBrowseState, LibraryRef>(
        LibraryBrowseNotifier.new);

/// Empty for a source without the capability. No automatic retry: a failed
/// row stays hidden until the next refresh rather than polling a down
/// server.
final sourceContinueWatchingProvider =
    StreamProvider.autoDispose.family<List<ItemSummary>, SourceId>(
  (ref, id) {
    final continueWatching = _require(ref, id).as<ContinueWatching>();
    if (continueWatching == null) return Stream.value(const []);
    return createSourceWatcher(
      ref,
      key: SourceKeys.continueWatching(id),
      fetch: continueWatching.continueWatching,
      encode: encodeSummaries,
      decode: decodeSummaries,
    ).stream;
  },
  retry: (_, __) => null,
);

/// Null for a source without hubs, whose home keeps one row per library.
final sourceHubsProvider =
    StreamProvider.autoDispose.family<List<Hub>?, SourceId>(
  (ref, id) {
    final hubs = _require(ref, id).as<HomeHubs>();
    if (hubs == null) return Stream.value(null);
    return createSourceWatcher<List<Hub>?>(
      ref,
      key: SourceKeys.hubs(id),
      fetch: hubs.hubs,
      encode: encodeHubs,
      decode: decodeHubs,
    ).stream;
  },
  retry: (_, __) => null,
);

/// Progress or watched state changed: this item, its siblings in a season
/// list, and the home rows and grids that show it are all stale.
void invalidateSourceItemWrites(WidgetRef ref, ItemRef item) =>
    _invalidateWrites(ref.invalidate, item);

/// [invalidateSourceItemWrites] through a container, for a write that
/// finishes after its notifier is disposed: a `Ref` throws then, a container
/// does not.
void invalidateSourceContainerWrites(
  ProviderContainer container,
  ItemRef item,
) =>
    _invalidateWrites(container.invalidate, item);

void _invalidateWrites(
  void Function(ProviderOrFamily provider) invalidate,
  ItemRef item,
) {
  invalidate(sourceItemProvider(item));
  invalidate(sourceChildrenProvider);
  invalidate(sourceLibraryPreviewProvider);
  invalidate(libraryBrowseProvider);
  invalidate(sourceContinueWatchingProvider(item.sourceId));
  invalidate(sourceHubsProvider(item.sourceId));
}
