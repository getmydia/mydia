import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/collection_auto_sync.dart';
import 'package:player/core/downloads/collection_sync_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const collectionId = 'col-1';
  final syncConfigs = {
    collectionId: {'name': 'Favorites', 'resolution': '1080p'},
  };

  ({
    ProviderContainer container,
    CollectionAutoSync autoSync,
  }) makeHarness({
    required void Function() onFetchCollections,
    required DateTime Function() now,
  }) {
    final container = ProviderContainer(
      overrides: [
        allSyncedCollectionsProvider.overrideWith((ref) async {
          onFetchCollections();
          return syncConfigs;
        }),
      ],
    );
    addTearDown(container.dispose);
    return (
      container: container,
      autoSync: CollectionAutoSync.forTest(
        read: container.read,
        now: now,
      ),
    );
  }

  group('CollectionAutoSync.run', () {
    test('skips work when called again within the five-minute debounce window',
        () async {
      final baseTime = DateTime(2026, 8, 9, 12, 0);
      var currentTime = baseTime;
      var fetchCount = 0;

      final harness = makeHarness(
        onFetchCollections: () => fetchCount++,
        now: () => currentTime,
      );

      await harness.autoSync.run();
      expect(fetchCount, 1);

      currentTime = baseTime.add(const Duration(minutes: 2));
      expect(await harness.autoSync.run(), 0);
      expect(fetchCount, 1);
    });

    test('runs again after the debounce window expires', () async {
      final baseTime = DateTime(2026, 8, 9, 12, 0);
      var currentTime = baseTime;
      var fetchCount = 0;

      final harness = makeHarness(
        onFetchCollections: () => fetchCount++,
        now: () => currentTime,
      );

      await harness.autoSync.run();
      expect(fetchCount, 1);

      currentTime = baseTime.add(const Duration(minutes: 6));
      harness.container.invalidate(allSyncedCollectionsProvider);
      await harness.autoSync.run();
      expect(fetchCount, 2);
    });
  });
}
