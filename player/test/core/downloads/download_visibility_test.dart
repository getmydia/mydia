import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/download.dart';

import '../../presentation/screens/sources/fake_media_source.dart';
import 'download_test_harness.dart';
import '../../test_utils/mydia_test_source.dart';

void main() {
  test('sources are visible only while listed', () {
    final hidden = ProviderContainer(overrides: [
      thirdPartySourcesProvider.overrideWithValue([testMydiaSource])
    ]);
    addTearDown(hidden.dispose);
    expect(hidden.read(visibleDownloadSourcesProvider), {testMydiaSourceId});

    final shown = ProviderContainer(overrides: [
      thirdPartySourcesProvider.overrideWithValue([testMydiaSource, fakeSource])
    ]);
    addTearDown(shown.dispose);
    expect(shown.read(visibleDownloadSourcesProvider),
        {testMydiaSourceId, fakeSourceId});
  });

  group('the lists', () {
    late DownloadHarness h;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      h = await makeHarness(body: Uint8List(0));
      for (final source in [testMydiaSourceId.value, fakeSourceId.value]) {
        final tag = source == testMydiaSourceId.value ? 'mydia' : 'plex';
        await h.database.saveMedia(DownloadedMedia(
          id: 'm-$tag',
          mediaId: '42',
          title: 'Quill Harbor',
          quality: 'original',
          filePath: '/nowhere/$tag',
          fileSize: 1,
          downloadedAt: DateTime(2026),
          sourceId: source,
        ));
        await h.database.saveTask(DownloadTask(
          id: 'q-$tag',
          mediaId: '42',
          title: 'Quill Harbor',
          quality: 'original',
          status: 'downloading',
          createdAt: DateTime(2026),
          sourceId: source,
        ));
        await h.database.saveTask(DownloadTask(
          id: 'f-$tag',
          mediaId: '43',
          title: 'Quill Harbor',
          quality: 'original',
          status: 'failed',
          createdAt: DateTime(2026),
          sourceId: source,
        ));
      }
    });

    tearDown(() => h.dispose());

    ProviderContainer container(List<Source> listed) {
      final c = ProviderContainer(overrides: [
        downloadDatabaseProvider.overrideWith((ref) async => h.database),
        downloadManagerProvider.overrideWith((ref) async => h.service),
        thirdPartySourcesProvider.overrideWithValue(listed),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    AsyncValue<List<T>> Function() listen<T>(
        ProviderContainer c, ProviderListenable<AsyncValue<List<T>>> p) {
      final sub = c.listen(p, (_, __) {});
      addTearDown(sub.close);
      return sub.read;
    }

    // The first value of a stream provider, listened to so it stays alive.
    Future<Set<SourceId>> ids<T>(
      AsyncValue<List<T>> Function() read,
      SourceId Function(T) sourceOf,
    ) async {
      while (!read().hasValue) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return {for (final r in read().requireValue) sourceOf(r)};
    }

    test('drop a hidden source and keep a listed one', () async {
      final hidden = container([testMydiaSource]);
      final shown = container([testMydiaSource, fakeSource]);
      final both = {testMydiaSourceId, fakeSourceId};
      final mydia = {testMydiaSourceId};

      expect(
          await ids<DownloadedMedia>(
              listen(hidden, downloadedMediaProvider), (x) => x.source),
          mydia);
      expect(
          await ids<DownloadTask>(
              listen(hidden, downloadQueueProvider), (x) => x.source),
          mydia);
      expect(
          await ids<DownloadTask>(
              listen(hidden, failedDownloadsProvider), (x) => x.source),
          mydia);
      expect(
          await ids<DownloadedMedia>(
              listen(shown, downloadedMediaProvider), (x) => x.source),
          both);
      expect(
          await ids<DownloadTask>(
              listen(shown, downloadQueueProvider), (x) => x.source),
          both);
      expect(
          await ids<DownloadTask>(
              listen(shown, failedDownloadsProvider), (x) => x.source),
          both);
    });
  });
}
