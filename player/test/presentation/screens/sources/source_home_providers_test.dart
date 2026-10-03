import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
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

  test('Continue Watching is empty for a source without it', () async {
    final container = containerFor(FakeMediaSource());
    expect(
      await container.read(sourceContinueWatchingProvider(fakeSourceId).future),
      isEmpty,
    );
  });

  test('Continue Watching comes from a source that has it', () async {
    final container = containerFor(FakeResumingSource());
    final items = await container
        .read(sourceContinueWatchingProvider(fakeSourceId).future);
    expect(items.map((i) => i.ref.externalId), ['e2', 'm3']);
  });

  test('hubs are null for a source without them', () async {
    final container = containerFor(FakeResumingSource());
    expect(
        await container.read(sourceHubsProvider(fakeSourceId).future), isNull);
  });

  test('hubs come from a source that has them', () async {
    final container = containerFor(FakeHubSource());
    final hubs = await container.read(sourceHubsProvider(fakeSourceId).future);
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
}
