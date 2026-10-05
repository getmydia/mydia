import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/downloads/orphan_download_sweep.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/models/download.dart';

import '../sources/store/source_json_test.dart' show plexRecord;
import 'download_test_harness.dart';

class _Records extends SourceRecordsNotifier {
  _Records(this._load);
  final Future<SourceSnapshot> Function() _load;

  @override
  Future<SourceSnapshot> build() => _load();
}

class _RecordingService extends Fake implements DownloadService {
  final calls = <Set<String>>[];

  @override
  Future<int> deleteDownloadsOfUnknownAccounts(Set<String> known) async {
    calls.add(known);
    return 0;
  }
}

void main() {
  test('only the tasks and files of unknown accounts go', () async {
    final h = await makeHarness(body: Uint8List(0));
    addTearDown(h.dispose);
    Future<String> media(String id, String? source) async {
      final file = File('${h.downloadDir.path}/$id')..writeAsBytesSync([1]);
      await h.database.saveMedia(DownloadedMedia(
          id: id,
          mediaId: id,
          title: 'Quill Harbor',
          quality: 'original',
          filePath: file.path,
          fileSize: 1,
          downloadedAt: DateTime(2026),
          sourceId: source));
      return file.path;
    }

    final gone = await media('a', 'gone1:owner:aa11');
    final goneKid = await media('b', 'gone1:kid:aa11');
    final goneOther = await media('c', 'gone2:owner:bb22');
    final known = await media('d', 'acc1:owner:aa11');
    final home = await media('e', null);
    await h.database.saveTask(DownloadTask(
        id: 't1',
        mediaId: 'm-t1',
        title: 'Quill Harbor',
        quality: 'original',
        status: 'interrupted',
        sourceId: 'gone1:owner:aa11',
        createdAt: DateTime(2026)));
    await h.database.saveTask(DownloadTask(
        id: 't2',
        mediaId: 'm-t2',
        title: 'Quill Harbor',
        quality: 'original',
        status: 'interrupted',
        sourceId: 'acc1:owner:aa11',
        createdAt: DateTime(2026)));

    expect(await h.service.deleteDownloadsOfUnknownAccounts({'acc1'}), 3);

    for (final path in [gone, goneKid, goneOther]) {
      expect(File(path).existsSync(), isFalse);
    }
    expect(File(known).existsSync(), isTrue);
    expect(File(home).existsSync(), isTrue);
    expect(h.service.getDownloadedMedia().map((m) => m.id).toSet(), {'d', 'e'});
    expect(h.database.getTask('t1'), isNull);
    expect(h.database.getTask('t2'), isNotNull);
  });

  group('the trigger', () {
    late _RecordingService service;

    ProviderContainer build(Future<SourceSnapshot> Function() records) {
      service = _RecordingService();
      final container = ProviderContainer(overrides: [
        downloadManagerProvider.overrideWith((ref) async => service),
        sourceRecordsProvider.overrideWith(() => _Records(records)),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    Future<void> settle() => Future<void>.delayed(
          const Duration(milliseconds: 50),
        );

    test('does nothing while the records are loading', () async {
      final gate = Completer<SourceSnapshot>();
      final container = build(() => gate.future);
      container.read(orphanDownloadSweepProvider);
      await settle();
      expect(service.calls, isEmpty);

      gate.complete(SourceSnapshot(accounts: [plexRecord()]));
      await settle();
      expect(service.calls, [
        {'acc1'}
      ]);
    });

    test('does nothing when the records failed to load', () async {
      final container = build(() => Future.error(StateError('store broke')));
      container.read(orphanDownloadSweepProvider);
      await settle();
      expect(service.calls, isEmpty);
    });

    test('runs once per session', () async {
      final container = build(() async => const SourceSnapshot(accounts: []));
      container.read(orphanDownloadSweepProvider);
      await settle();
      container.invalidate(sourceRecordsProvider);
      await container.read(sourceRecordsProvider.future);
      await settle();
      expect(service.calls, hasLength(1));
      expect(service.calls.single, isEmpty);
    });
  });
}
