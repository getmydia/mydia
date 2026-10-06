import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';

DownloadTask _task(
        {String? sourceId, String? itemKind, String mediaType = 'movie'}) =>
    DownloadTask(
      id: 't1',
      mediaId: '42',
      title: 'Quill Harbor',
      quality: 'original',
      mediaType: mediaType,
      createdAt: DateTime(2026, 1, 1),
      sourceId: sourceId,
      itemKind: itemKind,
    );

void main() {
  test('a record with no source reads as home Mydia', () {
    final task = _task(mediaType: 'episode');
    expect(task.source, SourceId.legacyMydia);
    expect(
        task.itemRef,
        const ItemRef(
            sourceId: SourceId.legacyMydia,
            kind: ItemKind.episode,
            externalId: '42'));
  });

  test('a stored kind wins over mediaType', () {
    final task = _task(sourceId: 'acc1:owner:aa11', itemKind: 'video');
    expect(task.itemRef.kind, ItemKind.video);
    expect(task.source, const SourceId('acc1:owner:aa11'));
  });

  test('matches compares source and id, not kind', () {
    final task = _task(sourceId: 'acc1:owner:aa11');
    expect(
        task.matches(const ItemRef(
            sourceId: SourceId('acc1:owner:aa11'),
            kind: ItemKind.episode,
            externalId: '42')),
        isTrue);
    expect(
        task.matches(const ItemRef(
            sourceId: SourceId.legacyMydia,
            kind: ItemKind.movie,
            externalId: '42')),
        isFalse);
  });

  test('fromTask carries the source fields across', () {
    final media = DownloadedMedia.fromTask(
        _task(sourceId: 'acc1:owner:aa11', itemKind: 'video').copyWith(
            filePath: '/d/a.mkv',
            fileSize: 10,
            posterPath: '/d/a.mkv.poster.jpg'));
    expect(media.source, const SourceId('acc1:owner:aa11'));
    expect(media.itemRef.kind, ItemKind.video);
    expect(media.posterPath, '/d/a.mkv.poster.jpg');
  });

  test('copyWith can clear the job id and the error', () {
    final task = _task().copyWith(transcodeJobId: 'j', error: 'boom');
    final cleared = task.copyWith(clearTranscodeJobId: true, clearError: true);
    expect(cleared.transcodeJobId, isNull);
    expect(cleared.error, isNull);
  });

  test('survives a Hive round trip', () async {
    final dir = await Directory.systemTemp.createTemp('dl_src_');
    addTearDown(() => dir.delete(recursive: true));
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    final box = await Hive.openBox<DownloadTask>('t');
    await box.put('t1', _task(sourceId: 'acc1:owner:aa11', itemKind: 'video'));
    await box.close();
    final reopened = await Hive.openBox<DownloadTask>('t');
    expect(reopened.get('t1')!.itemRef.kind, ItemKind.video);
    await reopened.close();
  });
}
