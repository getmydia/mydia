import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/source_detail_controllers.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';

import 'fake_media_source.dart';

class _CountingSource extends FakeMediaSource {
  int itemCalls = 0;

  @override
  Future<ItemDetail> item(ItemRef ref) {
    itemCalls++;
    return super.item(ref);
  }
}

void main() {
  test('a watched write refetches the live item and colds the rest', () async {
    final log = InMemoryFetchLog();
    final source = _CountingSource();
    final c = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      fetchLogProvider.overrideWithValue(log),
    ]);
    addTearDown(c.dispose);

    final live = fakeMovie(1).ref;
    c.listen(sourceItemProvider(live), (_, __) {});
    await c.read(sourceItemProvider(live).future);
    await pumpEventQueue();

    final dormant = SourceKeys.item(fakeMovie(2).ref);
    await log.record(dormant, DateTime.now());

    final before = source.itemCalls;
    invalidateSourceContainerWrites(c, live);
    await pumpEventQueue();

    expect(source.itemCalls, before + 1, reason: 'the live item refetched');
    expect(log.lastFetchedAt(dormant), isNull,
        reason: 'the dormant item mounts cold next time');
  });

  test('a detail write goes through the same rule', () async {
    final log = InMemoryFetchLog();
    final c = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(_CountingSource()),
      fetchLogProvider.overrideWithValue(log),
    ]);
    addTearDown(c.dispose);
    final key = SourceKeys.continueWatching(fakeSourceId);
    await log.record(key, DateTime.now());

    invalidateSourceDetailWrites(c, fakeMovie(1).ref);
    await pumpEventQueue();
    expect(log.lastFetchedAt(key), isNull);
  });
}
