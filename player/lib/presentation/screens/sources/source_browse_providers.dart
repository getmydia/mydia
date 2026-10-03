/// Per-screen state for the generic source screens, keyed by source. Each
/// screen invalidates its own providers after a write; nothing here is
/// wired to Mydia's `QueryWatcher`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';

MediaSource _require(Ref ref, SourceId id) =>
    ref.watch(mediaSourceProvider(id)) ??
    (throw const SourceException.notFound());

String sourceItemLocation(ItemRef ref) =>
    '/s/${ref.sourceId.value}/item/${ref.kind.name}/${Uri.encodeComponent(ref.externalId)}';

final sourceLibrariesProvider = FutureProvider.autoDispose
    .family<List<Library>, SourceId>(
        (ref, id) => _require(ref, id).libraries());

/// The home row for [library]: its "Recently added" sort when it has one.
final sourceLibraryPreviewProvider = FutureProvider.autoDispose
    .family<List<ItemSummary>, LibraryRef>((ref, library) async {
  final source = _require(ref, library.sourceId);
  final libraries =
      await ref.watch(sourceLibrariesProvider(library.sourceId).future);
  final options =
      libraries.where((l) => l.ref == library).firstOrNull?.sortOptions ??
          const [];
  final recent = options.where((o) => o.label == 'Recently added').firstOrNull;
  final page = await source.browse(
    library,
    BrowseQuery(sortId: recent?.id, pageSize: 20),
  );
  return page.items;
});

final sourceItemProvider = FutureProvider.autoDispose
    .family<ItemDetail, ItemRef>(
        (ref, item) => _require(ref, item.sourceId).item(item));

/// Every child of [parent], following pages up to a sane cap.
final sourceChildrenProvider = FutureProvider.autoDispose
    .family<List<ItemSummary>, ItemRef>((ref, parent) async {
  final source = _require(ref, parent.sourceId);
  final items = <ItemSummary>[];
  Cursor? cursor;
  for (var pages = 0; pages < 10; pages++) {
    final page = await source.children(parent, cursor: cursor);
    items.addAll(page.items);
    cursor = page.nextCursor;
    if (cursor == null) break;
  }
  return items;
});

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

class LibraryBrowseNotifier extends AsyncNotifier<LibraryBrowseState> {
  LibraryBrowseNotifier(this.library);

  final LibraryRef library;
  BrowseQuery _query = const BrowseQuery();

  @override
  Future<LibraryBrowseState> build() async {
    final source = _require(ref, library.sourceId);
    final page = await source.browse(library, _query);
    return LibraryBrowseState(
      query: _query,
      items: page.items,
      nextCursor: page.nextCursor,
      total: page.total,
    );
  }

  Future<void> setQuery(BrowseQuery query) async {
    _query = query;
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
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _require(ref, library.sourceId)
          .browse(library, current.query, cursor: cursor);
      if (!ref.mounted) return;
      state = AsyncData(current.copyWith(
        items: [...current.items, ...page.items],
        nextCursor: page.nextCursor,
        clearCursor: page.nextCursor == null,
        loadingMore: false,
      ));
    } on SourceException {
      if (ref.mounted) state = AsyncData(current.copyWith(loadingMore: false));
    }
  }
}

final libraryBrowseProvider = AsyncNotifierProvider.autoDispose
    .family<LibraryBrowseNotifier, LibraryBrowseState, LibraryRef>(
        LibraryBrowseNotifier.new);
