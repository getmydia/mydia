/// One cached, paged list for every source listing: a library, the unwatched
/// and favorites lists, a collection. What differs between them is a
/// [SourcePages] value, which is the family argument of
/// [sourcePagesProvider].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/query_key.dart';
import '../../../core/sources/cache/create_source_watcher.dart';
import '../../../core/sources/cache/source_codecs.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import 'source_browse_providers.dart';

/// A paged list of items on one source. Equal when their cache keys are,
/// which makes them safe Riverpod family arguments.
sealed class SourcePages {
  const SourcePages();

  SourceId get sourceId;
  QueryKey get key;
  Future<Page<ItemSummary>> fetch(MediaSource source, Cursor? cursor);

  @override
  bool operator ==(Object other) =>
      other is SourcePages &&
      other.runtimeType == runtimeType &&
      other.key == key;

  @override
  int get hashCode => key.hashCode;
}

final class LibraryPages extends SourcePages {
  const LibraryPages(this.library, this.query);

  final LibraryRef library;
  final BrowseQuery query;

  @override
  SourceId get sourceId => library.sourceId;

  @override
  QueryKey get key => SourceKeys.browse(library, query);

  @override
  Future<Page<ItemSummary>> fetch(MediaSource s, Cursor? c) =>
      s.browse(library, query, cursor: c);
}

final class UnwatchedPages extends SourcePages {
  const UnwatchedPages(this.sourceId);

  @override
  final SourceId sourceId;

  @override
  QueryKey get key => SourceKeys.unwatched(sourceId);

  @override
  Future<Page<ItemSummary>> fetch(MediaSource s, Cursor? c) =>
      (s.as<UnwatchedListing>() ?? (throw const SourceException.unsupported()))
          .unwatched(cursor: c);
}

final class FavoritePages extends SourcePages {
  const FavoritePages(this.sourceId);

  @override
  final SourceId sourceId;

  @override
  QueryKey get key => SourceKeys.favorites(sourceId);

  @override
  Future<Page<ItemSummary>> fetch(MediaSource s, Cursor? c) =>
      (s.as<FavoritesListing>() ?? (throw const SourceException.unsupported()))
          .favorites(cursor: c);
}

final class CollectionPages extends SourcePages {
  const CollectionPages(this.sourceId, this.collectionId);

  @override
  final SourceId sourceId;
  final String collectionId;

  @override
  QueryKey get key => SourceKeys.collectionItems(sourceId, collectionId);

  @override
  Future<Page<ItemSummary>> fetch(MediaSource s, Cursor? c) =>
      (s.as<Collections>() ?? (throw const SourceException.unsupported()))
          .collectionItems(collectionId, cursor: c);
}

class PagedItems {
  const PagedItems({
    required this.items,
    this.nextCursor,
    this.total,
    this.loadingMore = false,
  });

  final List<ItemSummary> items;
  final Cursor? nextCursor;
  final int? total;
  final bool loadingMore;

  PagedItems copyWith({
    List<ItemSummary>? items,
    Cursor? nextCursor,
    bool clearCursor = false,
    bool? loadingMore,
  }) =>
      PagedItems(
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        total: total,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

class SourcePagesNotifier extends StreamNotifier<PagedItems> {
  SourcePagesNotifier(this.pages);

  final SourcePages pages;

  /// Bumped whenever the list is rebuilt, so a page that was requested for
  /// the previous build is dropped when it lands.
  int _generation = 0;

  /// Set once the viewer asks for page 2. From then on the watcher declines
  /// automatic refetches and its page-1 answers are ignored: either would
  /// collapse the pages already on screen. Only page 1 is cached. A cached
  /// page 1 may emit before the fresh one, so paging in that window uses the
  /// cached cursor.
  bool _paged = false;

  @override
  Stream<PagedItems> build() {
    _generation++;
    _paged = false;
    final source = requireSource(ref, pages.sourceId);
    final watcher = createSourceWatcher<Page<ItemSummary>>(
      ref,
      key: pages.key,
      fetch: () => pages.fetch(source, null),
      encode: encodeSummaryPage,
      decode: decodeSummaryPage,
      canRefetch: () => !_paged,
    );
    return watcher.stream.where((_) => !_paged).map(
          (page) => PagedItems(
            items: page.items,
            nextCursor: page.nextCursor,
            total: page.total,
          ),
        );
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
      final page =
          await pages.fetch(requireSource(ref, pages.sourceId), cursor);
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
        // Page 2 never landed, so page 1 is still the whole list: let the
        // watcher refresh it again.
        _paged = false;
        state = AsyncData(current.copyWith(loadingMore: false));
      }
    }
  }
}

final sourcePagesProvider = StreamNotifierProvider.autoDispose
    .family<SourcePagesNotifier, PagedItems, SourcePages>(
        SourcePagesNotifier.new);

/// The query a library screen shows, remembered while the screen lives.
final libraryQueryProvider = NotifierProvider.autoDispose
    .family<LibraryQueryNotifier, BrowseQuery, LibraryRef>(
        LibraryQueryNotifier.new);

class LibraryQueryNotifier extends Notifier<BrowseQuery> {
  LibraryQueryNotifier(this.library);

  final LibraryRef library;

  @override
  BrowseQuery build() => const BrowseQuery();

  void set(BrowseQuery query) => state = query;
}
