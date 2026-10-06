import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/downloads/orphan_download_sweep.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/models/download.dart';

import '../sources/store/source_json_test.dart' show plexRecord;
import '../../test_utils/mydia_test_source.dart';
import 'download_test_harness.dart';

class _Records extends SourceRecordsNotifier {
  _Records(this._load);
  final Future<SourceSnapshot> Function() _load;

  @override
  Future<SourceSnapshot> build() => _load();

  void emit(SourceSnapshot next) => state = AsyncData(next);

  void fail() => state = AsyncError(StateError('boom'), StackTrace.empty);
}

SourceAccountRecord _secondAccount() => SourceAccountRecord(
      account: const ProviderAccount(
        id: 'acc2',
        kind: SourceKind.plex,
        displayName: 'harbor',
        storageNamespace: 'source/acc2',
        activeProfileId: 'owner',
      ),
      profiles: const [
        SourceProfile(
            id: 'owner', accountId: 'acc2', name: 'Harbor', isOwner: true),
      ],
      servers: const [],
      addedAtMs: 1700000000000,
    );

class _RecordingService extends Fake implements DownloadService {
  final calls = <Set<String>>[];

  /// When set, each call waits for it before answering.
  Completer<void>? gate;

  @override
  Future<int> deleteDownloadsOfUnknownAccounts(Set<String> known) async {
    calls.add(known);
    await gate?.future;
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
    final mydia = await media('e', testMydiaSourceId.value);
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

    expect(
        await h.service.deleteDownloadsOfUnknownAccounts({'acc1', 'macct'}), 3);

    for (final path in [gone, goneKid, goneOther]) {
      expect(File(path).existsSync(), isFalse);
    }
    expect(File(known).existsSync(), isTrue);
    expect(File(mydia).existsSync(), isTrue);
    expect(h.service.getDownloadedMedia().map((m) => m.id).toSet(), {'d', 'e'});
    expect(h.database.getTask('t1'), isNull);
    expect(h.database.getTask('t2'), isNotNull);
  });

  test('downloads from before accounts survive a sweep that knows nothing',
      () async {
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

    DownloadTask task(String id, String? source) => DownloadTask(
        id: id,
        mediaId: 'm-$id',
        title: 'Quill Harbor',
        quality: 'original',
        status: 'interrupted',
        sourceId: source,
        createdAt: DateTime(2026));

    final unset = await media('a', null);
    final bare = await media('b', preAccountSourceId.value);
    final gone = await media('c', 'gone1:owner:aa11');
    await h.database.saveTask(task('t-null', null));
    await h.database.saveTask(task('t-bare', preAccountSourceId.value));
    await h.database.saveTask(task('t-gone', 'gone1:owner:aa11'));

    expect(await h.service.deleteDownloadsOfUnknownAccounts(<String>{}), 1);

    expect(File(unset).existsSync(), isTrue);
    expect(File(bare).existsSync(), isTrue);
    expect(File(gone).existsSync(), isFalse);
    expect(h.database.getTask('t-null'), isNotNull);
    expect(h.database.getTask('t-bare'), isNotNull);
    expect(h.database.getTask('t-gone'), isNull);

    expect(await h.service.deleteAccountDownloads('mydia'), 0,
        reason: 'removing an account never reaches pre-account records');
    expect(File(unset).existsSync(), isTrue);
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

    test('does not sweep again while the accounts are unchanged', () async {
      final container = build(() async => const SourceSnapshot(accounts: []));
      container.read(orphanDownloadSweepProvider);
      await settle();
      container.invalidate(sourceRecordsProvider);
      await container.read(sourceRecordsProvider.future);
      await settle();
      expect(service.calls, hasLength(1));
      expect(service.calls.single, isEmpty);
    });

    test('sweeps again when an account is removed after the first sweep',
        () async {
      final container = build(() async =>
          SourceSnapshot(accounts: [plexRecord(), _secondAccount()]));
      container.read(orphanDownloadSweepProvider);
      await settle();
      expect(service.calls, [
        {'acc1', 'acc2'}
      ]);

      (container.read(sourceRecordsProvider.notifier) as _Records)
          .emit(SourceSnapshot(accounts: [plexRecord()]));
      await settle();

      expect(service.calls, [
        {'acc1', 'acc2'},
        {'acc1'},
      ]);
    });

    test('a snapshot change during a sweep uses the fresh account set',
        () async {
      final managerGate = Completer<DownloadService>();
      service = _RecordingService();
      final container = ProviderContainer(overrides: [
        downloadManagerProvider.overrideWith((ref) => managerGate.future),
        sourceRecordsProvider.overrideWith(() => _Records(() async =>
            SourceSnapshot(accounts: [plexRecord(), _secondAccount()]))),
      ]);
      addTearDown(container.dispose);
      container.read(orphanDownloadSweepProvider);
      await settle();

      // The account goes while the sweep still waits for the manager.
      (container.read(sourceRecordsProvider.notifier) as _Records)
          .emit(SourceSnapshot(accounts: [plexRecord()]));
      await settle();
      managerGate.complete(service);
      await settle();

      expect(service.calls, [
        {'acc1'}
      ]);
    });

    test('a change during a running sweep runs one more afterwards', () async {
      final container = build(() async =>
          SourceSnapshot(accounts: [plexRecord(), _secondAccount()]));
      service.gate = Completer<void>();
      container.read(orphanDownloadSweepProvider);
      await settle();
      expect(service.calls, hasLength(1));

      final notifier =
          container.read(sourceRecordsProvider.notifier) as _Records;
      notifier.emit(SourceSnapshot(accounts: [plexRecord()]));
      await settle();
      // Collapsed into the running sweep, not started alongside it.
      expect(service.calls, hasLength(1));

      service.gate!.complete();
      await settle();
      expect(service.calls, [
        {'acc1', 'acc2'},
        {'acc1'},
      ]);
    });

    test('never sweeps on a later load or error', () async {
      final container =
          build(() async => SourceSnapshot(accounts: [plexRecord()]));
      container.read(orphanDownloadSweepProvider);
      await settle();
      expect(service.calls, hasLength(1));

      (container.read(sourceRecordsProvider.notifier) as _Records).fail();
      await settle();
      container.invalidate(sourceRecordsProvider);
      await settle();
      expect(service.calls, hasLength(1));
    });
  });
}
