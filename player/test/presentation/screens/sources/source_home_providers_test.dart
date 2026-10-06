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
}
