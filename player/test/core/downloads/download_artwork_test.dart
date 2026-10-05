import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';

import 'download_test_harness.dart';

Future<void> _untilSaved(DownloadHarness h, String id) async {
  for (var i = 0; i < 100 && h.database.getMedia(id)?.posterPath == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Deletes the media row while the artwork paths are being written to the
/// task, the window a user delete can land in.
class _DeleteWhileSavingArt extends HiveDownloadDatabase {
  _DeleteWhileSavingArt({required super.tasksBox, required super.mediaBox});

  bool raced = false;

  @override
  Future<void> saveTask(DownloadTask task) async {
    if (task.posterPath != null) {
      raced = true;
      await mediaBox.delete(task.id);
    }
    await super.saveTask(task);
  }
}

void main() {
  test('artwork lands next to the file and on the record', () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    final asked = <String>[];
    h.service.setArtworkFetcher((task, art) async {
      asked.add(art);
      return (
        url: 'https://test.invalid/$art',
        headers: const <String, String>{}
      );
    });

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, '9'),
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor',
          mediaType: MediaType.movie,
          posterUrl: 'p',
          backdropUrl: 'b'),
    ));
    await h.waitForStatus(task.id, 'completed');
    await _untilSaved(h, task.id);

    final media = h.database.getMedia(task.id)!;
    expect(asked, containsAll(['p', 'b']));
    expect(File(media.posterPath!).existsSync(), isTrue);
    expect(media.posterPath, startsWith(media.filePath));
    expect(media.thumbnailPath, isNull);

    await h.service.deleteDownload(media.itemRef);
    expect(File(media.posterPath!).existsSync(), isFalse);
  });

  test(
      'an episode saves the show poster as its poster and the still as its '
      'thumbnail', () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    final asked = <String>[];
    h.service.setArtworkFetcher((task, art) async {
      asked.add(art);
      return (
        url: 'https://test.invalid/$art',
        headers: const <String, String>{}
      );
    });

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.episode, '12'),
      optionId: 'original',
      metadata: const DownloadMetadata(
        title: 'The Lantern Accord',
        mediaType: MediaType.episode,
        posterUrl: 'still',
        showPosterUrl: 'show-poster',
        thumbnailUrl: 'thumb',
        showId: '3',
        showTitle: 'Quill Harbor',
        seasonNumber: 1,
        episodeNumber: 2,
      ),
    ));
    await h.waitForStatus(task.id, 'completed');
    await _untilSaved(h, task.id);
    for (var i = 0;
        i < 100 && h.database.getMedia(task.id)?.thumbnailPath == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final media = h.database.getMedia(task.id)!;
    expect(asked, unorderedEquals(['show-poster', 'thumb']));
    expect(File(media.posterPath!).existsSync(), isTrue);
    expect(File(media.thumbnailPath!).existsSync(), isTrue);
    expect(media.posterPath, isNot(media.thumbnailPath));
  });

  test('fetcher headers reach the artwork request', () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    h.service.setArtworkFetcher((task, art) async => (
          url: 'https://art.invalid/$art',
          headers: const <String, String>{'X-Test-Token': 'abc'},
        ));

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, '9'),
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor', mediaType: MediaType.movie, posterUrl: 'p'),
    ));
    await h.waitForStatus(task.id, 'completed');
    await _untilSaved(h, task.id);

    final art =
        h.adapter.requests.where((r) => r.uri.host == 'art.invalid').toList();
    expect(art, hasLength(1));
    expect(art.single.headers['X-Test-Token'], 'abc');
  });

  test('a delete landing during the artwork write leaves no art behind',
      () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    final racing = _DeleteWhileSavingArt(
        tasksBox: h.database.tasksBox, mediaBox: h.database.mediaBox);
    h.service.setDatabase(racing);
    h.service.setArtworkFetcher((task, art) async =>
        (url: 'https://test.invalid/$art', headers: const <String, String>{}));

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, '9'),
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor', mediaType: MediaType.movie, posterUrl: 'p'),
    ));
    await h.waitForStatus(task.id, 'completed');
    for (var i = 0; i < 100 && !racing.raced; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(racing.raced, isTrue);
    expect(h.database.getMedia(task.id), isNull);
    final leftovers =
        h.downloadDir.listSync().where((e) => e.path.endsWith('.poster.jpg'));
    expect(leftovers, isEmpty);
  });

  test('startup cleanup keeps the artwork of a completed download', () async {
    final h = await makeHarness(body: Uint8List.fromList([1, 2, 3]));
    addTearDown(h.dispose);
    h.service.setArtworkFetcher((task, art) async =>
        (url: 'https://test.invalid/$art', headers: const <String, String>{}));

    final task = await h.service.start(DownloadRequest(
      ref: homeMydiaRef(ItemKind.movie, '9'),
      optionId: 'original',
      metadata: const DownloadMetadata(
          title: 'Quill Harbor', mediaType: MediaType.movie, posterUrl: 'p'),
    ));
    await h.waitForStatus(task.id, 'completed');
    await _untilSaved(h, task.id);
    final media = h.database.getMedia(task.id)!;

    // setDatabase kicks off the cleanup microtask.
    h.service.setDatabase(h.database);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(File(media.filePath).existsSync(), isTrue);
    expect(File(media.posterPath!).existsSync(), isTrue);
  });
}
