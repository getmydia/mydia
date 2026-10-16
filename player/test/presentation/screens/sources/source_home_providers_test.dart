import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';

import '../../../domain/merged/fake_merged_source.dart' as merged;
import 'fake_media_source.dart';

void main() {
  ProviderContainer containerFor(FakeMediaSource source) {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// The first value of [provider]. A listener keeps the autoDispose stream
  /// provider alive until it emits; a bare `read(provider.future)` does not.
  Future<T> firstValue<T>(ProviderContainer c, StreamProvider<T> provider) {
    c.listen(provider, (_, __) {});
    return c.read(provider.future);
  }

  test('Continue Watching is empty for a source without it', () async {
    final container = containerFor(FakeMediaSource());
    expect(
      await firstValue(container, sourceContinueWatchingProvider(fakeSourceId)),
      isEmpty,
    );
  });

  test('Continue Watching comes from a source that has it', () async {
    final container = containerFor(FakeResumingSource());
    final items = await firstValue(
        container, sourceContinueWatchingProvider(fakeSourceId));
    expect(items.map((i) => i.ref.externalId), ['e2', 'm3']);
  });

  test('hubs are null for a source without them', () async {
    final container = containerFor(FakeResumingSource());
    expect(
        await firstValue(container, sourceHubsProvider(fakeSourceId)), isNull);
  });

  test('hubs come from a source that has them', () async {
    final container = containerFor(FakeHubSource());
    final hubs = await firstValue(container, sourceHubsProvider(fakeSourceId));
    expect(
        hubs?.map((h) => h.id), ['home.movies.recent', 'home.mixed.released']);
  });

  test('a library location encodes the id', () {
    expect(
      sourceLibraryLocation(
          const LibraryRef(sourceId: fakeSourceId, id: 'a/b')),
      '/s/acc1:owner:aa11/library/a%2Fb',
    );
  });

  test('a second mount shows the stored rail before the server answers',
      () async {
    final cache = InMemorySourceCache();
    final log = InMemoryFetchLog();
    final source = FakeResumingSource();

    ProviderContainer mount() {
      final c = ProviderContainer(overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(source),
        sourceCacheProvider.overrideWithValue(cache),
        fetchLogProvider.overrideWithValue(log),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    final first = mount();
    await firstValue(first, sourceContinueWatchingProvider(fakeSourceId));
    await pumpEventQueue();
    expect(cache.read(SourceKeys.continueWatching(fakeSourceId)), isNotNull);
    // `first` stays alive (its teardown disposes it); the second container
    // shares only the cache and the fetch log.

    source.hold = Completer<void>();
    final second = mount();
    final items =
        await firstValue(second, sourceContinueWatchingProvider(fakeSourceId));
    expect(items.map((i) => i.ref.externalId), ['e2', 'm3'],
        reason: 'served from the cache while the fetch is held');
    source.hold!.complete();
  });

  test('the favorites row is the first page of favorites', () async {
    final s = merged.fakeServer('a');
    final source = merged.FakeMergedSource(s,
        favs: [
          merged.item(s, 'f1'),
          merged.item(s, 'f2'),
          merged.item(s, 'f3')
        ],
        favPageSize: 2);
    final c = ProviderContainer(overrides: [
      mediaSourceProvider(source.id).overrideWithValue(source),
    ]);
    addTearDown(c.dispose);
    final items = await firstValue(c, sourceFavoritesRowProvider(source.id));
    expect(items.map((i) => i.ref.externalId), ['f1', 'f2']);
  });

  test('the favorites row is empty for a source without the listing', () async {
    final container = containerFor(FakeMediaSource());
    expect(
      await firstValue(container, sourceFavoritesRowProvider(fakeSourceId)),
      isEmpty,
    );
  });

  test('the favorites row key is in the favorites family, apart from pages',
      () {
    expect(SourceKeys.favoritesRow(fakeSourceId),
        isNot(SourceKeys.favorites(fakeSourceId)));
    expect(
      SourceKeys.favoritesRow(fakeSourceId).operationName,
      (SourceKeys.family(fakeSourceId, SourceOps.favorites)).operationName,
    );
  });
}
