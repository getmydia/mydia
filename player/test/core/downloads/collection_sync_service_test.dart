import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/collection_sync_service.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/downloads/summary_download_metadata.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../../presentation/screens/sources/fake_capable_source.dart';
import '../../presentation/screens/sources/fake_media_source.dart';

ItemSummary _season(String id, int n) => ItemSummary(
      ref: ItemRef(
          sourceId: fakeSourceId, kind: ItemKind.season, externalId: id),
      title: 'Season $n',
      index: n,
    );

ItemSummary _episode(String id, int season, int n) => ItemSummary(
      ref: ItemRef(
          sourceId: fakeSourceId, kind: ItemKind.episode, externalId: id),
      title: 'Invented Episode $n',
      showTitle: 'Invented Series',
      parentIndex: season,
      index: n,
      defaultVersionId: 'v$id',
    );

/// Like [_SeasonedSource], but the movie `m2` has no file and the episode
/// `e12` names no version.
class _FilelessSource extends _SeasonedSource {
  @override
  Future<ItemDetail> item(ItemRef ref) async => ref.externalId == 'm2'
      ? ItemDetail(summary: fakeMovie(2))
      : super.item(ref);

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    final page = await super.children(parent, cursor: cursor);
    return Page(items: [
      for (final i in page.items)
        i.ref.externalId == 'e12'
            ? ItemSummary(ref: i.ref, title: i.title, index: i.index)
            : i,
    ]);
  }
}

/// A show with two seasons of two episodes each.
class _SeasonedSource extends FakeCapableSource {
  final childCalls = <String>[];

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async {
    childCalls.add(parent.externalId);
    return switch (parent.externalId) {
      's1' => Page(items: [_season('se1', 1), _season('se2', 2)]),
      'se1' => Page(items: [_episode('e11', 1, 1), _episode('e12', 1, 2)]),
      'se2' => Page(items: [_episode('e21', 2, 1), _episode('e22', 2, 2)]),
      _ => const Page(items: []),
    };
  }
}

/// A service that reports [downloaded] as on the device, starts everything
/// else, and records what it was asked for.
class _RecordingService extends Fake implements DownloadService {
  _RecordingService({this.downloaded = const {}});

  final Set<String> downloaded;
  final requests = <DownloadRequest>[];

  @override
  List<DownloadTask> getActiveDownloads() => const [];

  @override
  bool isDownloaded(ItemRef ref) => downloaded.contains(ref.externalId);

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
  test('queues movies and every episode of a show at the chosen option',
      () async {
    final source = _SeasonedSource();
    final service = _RecordingService(downloaded: {'m1'});

    final result = await syncCollectionItems(
      source: source,
      items: [fakeMovie(1), fakeMovie(2), fakeShow],
      optionId: '720p',
      manager: service,
      queue: const [],
      metadataFor: summaryDownloadMetadata,
    );

    expect(result.moviesQueued, 1);
    expect(result.episodesQueued, 4);
    expect(result.skipped, 1);
    expect(result.failed, 0);
    expect(service.requests.map((r) => r.ref.externalId),
        ['m2', 'e11', 'e12', 'e21', 'e22']);
    expect(service.requests.every((r) => r.optionId == '720p'), isTrue);
    expect(source.childCalls, ['s1', 'se1', 'se2']);
  });

  test('items with no file to download are skipped, not failed', () async {
    final service = _RecordingService();

    final result = await syncCollectionItems(
      source: _FilelessSource(),
      items: [fakeMovie(1), fakeMovie(2), fakeShow],
      optionId: 'original',
      manager: service,
      queue: const [],
      metadataFor: summaryDownloadMetadata,
    );

    expect((result.moviesQueued, result.episodesQueued), (1, 3));
    expect((result.skipped, result.failed), (2, 0));
    expect(service.requests.map((r) => r.ref.externalId),
        isNot(containsAll(['m2', 'e12'])));
  });

  test('skips a movie that is already queued', () async {
    final service = _RecordingService();
    final queued = DownloadTask(
      id: 't1',
      mediaId: 'm1',
      title: 'x',
      quality: '720p',
      status: 'queued',
      sourceId: fakeSourceId.value,
      itemKind: ItemKind.movie.name,
      createdAt: DateTime(2026),
    );

    final result = await syncCollectionItems(
      source: _SeasonedSource(),
      items: [fakeMovie(1), fakeMovie(2)],
      optionId: 'original',
      manager: service,
      queue: [queued],
      metadataFor: summaryDownloadMetadata,
    );

    expect((result.moviesQueued, result.skipped), (1, 1));
    expect(service.requests.single.ref.externalId, 'm2');
  });

  test('names the series on an episode that came through a season', () async {
    final service = _RecordingService();

    await syncCollectionItems(
      source: _SeasonedSource(),
      items: [fakeShow],
      optionId: 'original',
      manager: service,
      queue: const [],
      metadataFor: summaryDownloadMetadata,
    );

    final metadata = service.requests.first.metadata;
    expect(metadata.mediaType, MediaType.episode);
    expect(metadata.showId, 's1');
    expect(metadata.showTitle, 'Invented Series');
    expect(metadata.title, 'Invented Series - S01E01: Invented Episode 1');
  });

  test('counts a show whose seasons cannot be listed as failed', () async {
    final result = await syncCollectionItems(
      source: _FailingSource(),
      items: [fakeShow, fakeMovie(1)],
      optionId: 'original',
      manager: _RecordingService(),
      queue: const [],
      metadataFor: summaryDownloadMetadata,
    );

    expect(
        (result.moviesQueued, result.episodesQueued, result.failed), (1, 0, 1));
  });

  test('allCollectionItems follows pages to the last one', () async {
    final source = FakeCapableSource()
      ..collectionItemPages = [
        Page(items: [fakeMovie(1)], nextCursor: const Cursor('1')),
        Page(items: [fakeMovie(2)], nextCursor: const Cursor('2')),
        Page(items: [fakeMovie(3)]),
      ];

    final items = await allCollectionItems(source, 'c1');

    expect(items.map((i) => i.ref.externalId), ['m1', 'm2', 'm3']);
    expect(source.calls, [
      'collectionItems(c1, null)',
      'collectionItems(c1, 1)',
      'collectionItems(c1, 2)',
    ]);
  });
}

class _FailingSource extends FakeCapableSource {
  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) =>
      throw StateError('down');
}
