import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/collection_auto_sync.dart';
import 'package:player/core/downloads/collection_sync_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../../presentation/screens/sources/fake_capable_source.dart';
import '../../presentation/screens/sources/fake_media_source.dart';
import '../../presentation/screens/sources/listing_harness.dart'
    show otherSourceId;

class _RecordingService extends Fake implements DownloadService {
  final requests = <DownloadRequest>[];

  @override
  List<DownloadTask> getActiveDownloads() => const [];

  @override
  bool isDownloaded(ItemRef ref) => false;

  @override
  Future<DownloadTask> start(DownloadRequest request) async {
    requests.add(request);
    return DownloadTask(
        id: request.ref.externalId,
        mediaId: request.ref.externalId,
        title: request.metadata.title,
        quality: request.optionId,
        status: 'queued',
        createdAt: DateTime(2026));
  }
}

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

  group('CollectionAutoSync.run over a source', () {
    ProviderContainer containerFor(
      Map<String, Map<String, String>> configs,
      Map<SourceId, FakeCapableSource> sources,
      _RecordingService service,
    ) {
      final container = ProviderContainer(
        overrides: [
          allSyncedCollectionsProvider.overrideWith((ref) async => configs),
          downloadManagerProvider.overrideWith((ref) async => service),
          for (final entry in sources.entries)
            mediaSourceProvider(entry.key).overrideWithValue(entry.value),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
        'syncs every page of a collection from the source it was saved on '
        'at the saved option', () async {
      final source = FakeCapableSource(id: otherSourceId)
        ..collectionItemPages = [
          Page(items: [fakeMovie(1)], nextCursor: const Cursor('1')),
          Page(items: [fakeMovie(2)]),
        ];
      final service = _RecordingService();
      final container = containerFor({
        'c1': {
          'name': 'Saga',
          'resolution': '720p',
          'sourceId': otherSourceId.value,
        },
      }, {
        otherSourceId: source,
      }, service);

      final queued =
          await CollectionAutoSync.forTest(read: container.read).run();

      expect(queued, 2);
      expect(service.requests.map((r) => (r.ref.externalId, r.optionId)),
          [('m1', '720p'), ('m2', '720p')]);
    });

    test('skips a collection whose source is gone', () async {
      final service = _RecordingService();
      final container = containerFor({
        'c1': {
          'name': 'Saga',
          'resolution': '720p',
          'sourceId': otherSourceId.value,
        },
      }, const {}, service);

      final queued =
          await CollectionAutoSync.forTest(read: container.read).run();

      expect(queued, 0);
      expect(service.requests, isEmpty);
    });
  });

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
