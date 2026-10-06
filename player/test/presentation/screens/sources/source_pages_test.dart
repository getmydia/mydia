import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/watcher_registry.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/cache/source_watcher.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/sources/source_pages.dart';

import 'fake_capable_source.dart';
import 'fake_media_source.dart';

/// Holds every follow-up page (one with a cursor) until released.
class _GatedSource extends FakeMediaSource {
  _GatedSource() : super(movieCount: 130);

  final gate = Completer<void>();
  Error? followUpError;

  /// Answers later first-page requests in reverse order, so a refetch is
  /// not equal to what is already on screen (equal answers are not emitted).
  bool reverseFirstPage = false;

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
      {Cursor? cursor}) async {
    if (cursor != null) {
      await gate.future;
      if (followUpError case final e?) throw e;
    }
    final page = await super.browse(library, query, cursor: cursor);
    if (cursor != null || !reverseFirstPage) return page;
    return Page(
      items: page.items.reversed.toList(),
      nextCursor: page.nextCursor,
      total: page.total,
    );
  }
}

/// Like [_GatedSource], and a first-page request can be held too.
class _RefetchGatedSource extends _GatedSource {
  Completer<void>? firstPageHold;

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
      {Cursor? cursor}) async {
    if (cursor == null) await firstPageHold?.future;
    return super.browse(library, query, cursor: cursor);
  }
}

void main() {
  const movies = FakeMediaSource.movies;
  const defaultPages = LibraryPages(movies, BrowseQuery());
  final provider = sourcePagesProvider(defaultPages);

  ProviderContainer containerFor(FakeMediaSource source,
      [SourcePages pages = defaultPages]) {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ]);
    addTearDown(container.dispose);
    container.listen(sourcePagesProvider(pages), (_, __) {});
    return container;
  }

  Future<void> invalidateWatched(ProviderContainer container) async {
    await container
        .read(invalidatorProvider)
        .invalidate(SourceRules.watchedChanged(fakeSourceId));
    await pumpEventQueue();
  }

  test('a page requested before a rebuild is dropped when it lands', () async {
    final source = _GatedSource();
    final container = containerFor(source);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final loading = notifier.loadMore();
    container.invalidate(provider);
    await container.read(provider.future);
    source.gate.complete();
    await loading;

    final state = container.read(provider).requireValue;
    expect(state.items, hasLength(60), reason: "only the rebuilt list's page");
    expect(state.loadingMore, isFalse);
  });

  test('a failure that is not a SourceException resets loadingMore', () async {
    final source = _GatedSource()..followUpError = StateError('boom');
    final container = containerFor(source);
    await container.read(provider.future);

    final loading = container.read(provider.notifier).loadMore();
    source.gate.complete();
    await loading;

    expect(container.read(provider).requireValue.loadingMore, isFalse);
  });

  test('a fresh page 1 that lands after paging does not collapse the list',
      () async {
    final source = _RefetchGatedSource();
    final container = containerFor(source);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    source.gate.complete();
    await notifier.loadMore();
    expect(container.read(provider).requireValue.items, hasLength(120));

    // An automatic refetch is declined once paged...
    final registry = container.read(watcherRegistryProvider);
    final watcher = registry.find(defaultPages.key)!;
    expect(await watcher.refetchAutomatically(), isFalse);

    // ...and a user refetch's page 1 does not replace the paged list.
    source.firstPageHold = Completer<void>();
    final refetch = (watcher as SourceWatcher).refetch();
    await pumpEventQueue();
    source.firstPageHold!.complete();
    await refetch;
    await pumpEventQueue();
    expect(container.read(provider).requireValue.items, hasLength(120));
  });

  test('a failed loadMore leaves page 1 refreshable', () async {
    final source = _GatedSource()..followUpError = StateError('boom');
    final container = containerFor(source);
    await container.read(provider.future);

    final loading = container.read(provider.notifier).loadMore();
    source.gate.complete();
    await loading;
    expect(container.read(provider).requireValue.items, hasLength(60));

    final watcher =
        container.read(watcherRegistryProvider).find(defaultPages.key)!;
    expect(await watcher.refetchAutomatically(), isTrue);

    source.reverseFirstPage = true;
    var emissions = 0;
    container.listen(provider, (_, __) => emissions++);
    await (watcher as SourceWatcher).refetch();
    await pumpEventQueue();
    expect(emissions, greaterThan(0),
        reason: 'a refetched page 1 must reach the list again');
  });

  test('a different query is a different list on its own watcher', () async {
    final source = _GatedSource();
    final container = containerFor(source);
    await container.read(provider.future);
    source.gate.complete();
    await container.read(provider.notifier).loadMore();

    const added = LibraryPages(movies, BrowseQuery(sortId: 'added'));
    container.listen(sourcePagesProvider(added), (_, __) {});
    final state = await container.read(sourcePagesProvider(added).future);
    expect(state.items, hasLength(60));
    expect(container.read(watcherRegistryProvider).find(added.key), isNotNull);
    expect(container.read(provider).requireValue.items, hasLength(120),
        reason: 'the first query keeps its pages');
  });

  test('a watched-state invalidation after loadMore keeps the pages', () async {
    final source = _GatedSource()..reverseFirstPage = true;
    final container = containerFor(source);
    await container.read(provider.future);
    source.gate.complete();
    await container.read(provider.notifier).loadMore();
    final before = container.read(provider).requireValue.items;
    expect(before, hasLength(120));

    await invalidateWatched(container);

    expect(container.read(provider).requireValue.items, before);
  });

  test('a failed page 2 resets the guard, so an invalidation refetches page 1',
      () async {
    final source = _GatedSource()..followUpError = StateError('boom');
    final container = containerFor(source);
    await container.read(provider.future);
    expect(
        container.read(provider).requireValue.items.first.ref.externalId, 'm1');
    final loading = container.read(provider.notifier).loadMore();
    source.gate.complete();
    await loading;

    source.reverseFirstPage = true;
    await invalidateWatched(container);

    expect(container.read(provider).requireValue.items.first.ref.externalId,
        'm60');
  });

  group('UnwatchedPages', () {
    ItemSummary at(int n) => fakeMovie(n);

    test('pages twice, then stops when nextCursor is null', () async {
      final source = FakeCapableSource()
        ..unwatchedPages = [
          Page(items: [at(1)], nextCursor: const Cursor('1'), total: 3),
          Page(items: [at(2)], nextCursor: const Cursor('2')),
          Page(items: [at(3)]),
        ];
      const pages = UnwatchedPages(fakeSourceId);
      final container = containerFor(source, pages);
      final unwatched = sourcePagesProvider(pages);
      await container.read(unwatched.future);
      final notifier = container.read(unwatched.notifier);

      await notifier.loadMore();
      await notifier.loadMore();
      await notifier.loadMore();

      final state = container.read(unwatched).requireValue;
      expect(state.items.map((i) => i.ref.externalId), ['m1', 'm2', 'm3']);
      expect(state.nextCursor, isNull);
      expect(state.total, 3);
      expect(source.calls, ['unwatched(null)', 'unwatched(1)', 'unwatched(2)'],
          reason: 'no fourth request once the cursor ran out');
    });
  });

  test('FavoritePages and CollectionPages page through their capability',
      () async {
    final source = FakeCapableSource()
      ..favoritePages = [
        Page(items: [fakeMovie(1)], nextCursor: const Cursor('1')),
        Page(items: [fakeMovie(2)]),
      ]
      ..collectionItemPages = [
        Page(items: [fakeMovie(3)])
      ];
    const favorites = FavoritePages(fakeSourceId);
    const collection = CollectionPages(fakeSourceId, 'c1');
    final container = containerFor(source, favorites);
    container.listen(sourcePagesProvider(collection), (_, __) {});

    await container.read(sourcePagesProvider(favorites).future);
    await container.read(sourcePagesProvider(favorites).notifier).loadMore();
    final collected =
        await container.read(sourcePagesProvider(collection).future);

    expect(
        container
            .read(sourcePagesProvider(favorites))
            .requireValue
            .items
            .map((i) => i.ref.externalId),
        ['m1', 'm2']);
    expect(collected.items.single.ref.externalId, 'm3');
    expect(source.calls, contains('collectionItems(c1, null)'));
  });

  test('pages are equal when their keys are', () {
    expect(const LibraryPages(movies, BrowseQuery()),
        const LibraryPages(movies, BrowseQuery()));
    expect(const LibraryPages(movies, BrowseQuery()).hashCode,
        const LibraryPages(movies, BrowseQuery()).hashCode);
    expect(const LibraryPages(movies, BrowseQuery()),
        isNot(const LibraryPages(movies, BrowseQuery(sortId: 'added'))));
    expect(const UnwatchedPages(fakeSourceId),
        isNot(const FavoritePages(fakeSourceId)));
    expect(const CollectionPages(fakeSourceId, 'a'),
        isNot(const CollectionPages(fakeSourceId, 'b')));
  });

  test('the library query is remembered per library', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final query = libraryQueryProvider(movies);
    container.listen(query, (_, __) {});
    expect(container.read(query), const BrowseQuery());
    container.read(query.notifier).set(const BrowseQuery(sortId: 'added'));
    expect(container.read(query).sortId, 'added');
    expect(container.read(libraryQueryProvider(FakeMediaSource.shows)),
        const BrowseQuery());
  });

  test('SourceKeys.browse is the key of LibraryPages', () {
    expect(defaultPages.key, SourceKeys.browse(movies, const BrowseQuery()));
  });
}
