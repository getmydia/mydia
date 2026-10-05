import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/watcher_registry.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_watcher.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';

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
  ProviderContainer containerFor(FakeMediaSource source) {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ]);
    addTearDown(container.dispose);
    container.listen(libraryBrowseProvider(FakeMediaSource.movies), (_, __) {});
    return container;
  }

  test('a page requested for the old query is dropped after setQuery',
      () async {
    final source = _GatedSource();
    final container = containerFor(source);
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final loading = notifier.loadMore();
    await notifier.setQuery(const BrowseQuery(sortId: 'added'));
    source.gate.complete();
    await loading;

    final state = container.read(provider).requireValue;
    expect(state.query.sortId, 'added');
    expect(state.items, hasLength(60), reason: "only the new query's page");
    expect(state.loadingMore, isFalse);
  });

  test('a failure that is not a SourceException resets loadingMore', () async {
    final source = _GatedSource()..followUpError = StateError('boom');
    final container = containerFor(source);
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
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
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    source.gate.complete();
    await notifier.loadMore();
    expect(container.read(provider).requireValue.items, hasLength(120));

    // An automatic refetch is declined once paged...
    final registry = container.read(watcherRegistryProvider);
    final watcher = registry
        .find(SourceKeys.browse(FakeMediaSource.movies, const BrowseQuery()))!;
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
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);

    final loading = container.read(provider.notifier).loadMore();
    source.gate.complete();
    await loading;
    expect(container.read(provider).requireValue.items, hasLength(60));

    final watcher = container
        .read(watcherRegistryProvider)
        .find(SourceKeys.browse(FakeMediaSource.movies, const BrowseQuery()))!;
    expect(await watcher.refetchAutomatically(), isTrue);

    source.reverseFirstPage = true;
    var emissions = 0;
    container.listen(provider, (_, __) => emissions++);
    await (watcher as SourceWatcher).refetch();
    await pumpEventQueue();
    expect(emissions, greaterThan(0),
        reason: 'a refetched page 1 must reach the list again');
  });

  test('setQuery starts a new watcher on page 1', () async {
    final source = _GatedSource();
    final container = containerFor(source);
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);
    source.gate.complete();
    await container.read(provider.notifier).loadMore();

    await container
        .read(provider.notifier)
        .setQuery(const BrowseQuery(sortId: 'added'));
    expect(container.read(provider).requireValue.items, hasLength(60));
    expect(
      container.read(watcherRegistryProvider).find(SourceKeys.browse(
          FakeMediaSource.movies, const BrowseQuery(sortId: 'added'))),
      isNotNull,
    );
  });
}
