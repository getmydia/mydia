import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/downloads/download_job_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_queue_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/models/download_settings.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';

import '../../presentation/screens/sources/fake_media_source.dart';
import '../sources/store/source_json_test.dart' show plexRecord;
import 'download_test_harness.dart';
import '../../test_utils/mydia_test_source.dart';

void main() {
  // The download provider graph reaches secure storage and other bindings on
  // the way to building a service.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDir;
  late Box<DownloadTask> tasksBox;
  late Box<DownloadedMedia> mediaBox;
  late HiveDownloadDatabase database;
  var boxCounter = 0;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('mydia_providers_');
    Hive.init(hiveDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(DownloadTaskAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(DownloadedMediaAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(DownloadSettingsAdapter());
    }

    boxCounter++;
    tasksBox = await Hive.openBox<DownloadTask>('prov_tasks_$boxCounter');
    mediaBox = await Hive.openBox<DownloadedMedia>('prov_media_$boxCounter');
    database = HiveDownloadDatabase(tasksBox: tasksBox, mediaBox: mediaBox);
  });

  tearDown(() async {
    await database.close();
    if (await hiveDir.exists()) await hiveDir.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      downloadDatabaseProvider.overrideWith((ref) async => database),
      // Cut the graph down to the question under test. Left real, this pulls
      // in the connection and GraphQL providers, whose async initialisation
      // outlives container teardown and errors out on a disposed Ref.
      unifiedDownloadJobServiceProvider.overrideWith((ref) => null),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// Save settings the way the storage sheet does.
  ///
  /// `keepAlive` on `updateDownloadSettingsProvider` is what lets this read the
  /// closure and await it with nothing watching the provider, which is exactly
  /// what downloads_screen.dart does. An earlier revision of this helper held a
  /// live subscription instead, which is why the provider losing its Ref at the
  /// first await went unnoticed until riverpod 3.3.2 (#744).
  Future<void> saveSettings(
    ProviderContainer container,
    DownloadSettings settings,
  ) async {
    await container.read(updateDownloadSettingsProvider)(settings);
    await container.read(downloadSettingsProvider.future);
  }

  test('saving download settings does not tear down the download service',
      () async {
    final container = makeContainer();

    final before = await container.read(downloadManagerProvider.future);

    // This is what the storage settings sheet does on save. It invalidates
    // downloadSettingsProvider, which used to rebuild downloadManagerProvider
    // and dispose the service, cancelling every download in flight.
    await saveSettings(
      container,
      const DownloadSettings(maxConcurrentDownloads: 4, autoStartQueued: false),
    );

    final after = await container.read(downloadManagerProvider.future);

    expect(identical(before, after), isTrue,
        reason: 'the service instance must survive a settings change');
  });

  test('a settings change still reaches the service', () async {
    final container = makeContainer();

    final service = await container.read(downloadManagerProvider.future);

    // One slot, so a second task has to queue.
    await saveSettings(
      container,
      const DownloadSettings(maxConcurrentDownloads: 1, autoStartQueued: true),
    );
    // ref.listen fires on the next microtask.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await database.saveTask(DownloadTask(
      id: 'occupying',
      mediaId: 'm0',
      title: 'Occupying',
      quality: '1080p',
      status: 'downloading',
      downloadUrl: 'https://test.invalid/0.mp4',
      sourceId: testMydiaSourceId.value,
      createdAt: DateTime(2026, 1, 1),
    ));

    final queued = await service.start(DownloadRequest(
      ref: testMydiaRef(ItemKind.movie, 'm1'),
      optionId: '1080p',
      metadata:
          const DownloadMetadata(title: 'Second', mediaType: MediaType.movie),
    ));

    expect(database.getTask(queued.id)!.status, 'queued',
        reason: 'the new limit of 1 must have reached the service');
  });

  group('a task whose source has no MediaSource right now', () {
    final seededAt = DateTime(2020);

    /// Seeds an interrupted Plex task, builds the manager over [records] (its
    /// sweep resolves the task at once) and returns the task once it has run.
    Future<DownloadTask> sweep(Future<SourceSnapshot> Function() records,
        {SourceId source = fakeSourceId, bool loaded = true}) async {
      await database.saveTask(DownloadTask(
        id: 'hidden-dl',
        mediaId: '42',
        title: 'Quill Harbor',
        quality: 'original',
        status: 'interrupted',
        sourceId: source.value,
        // Recent, or the startup cleanup deletes it once it has failed.
        createdAt: DateTime.now(),
        lastProgressAt: seededAt,
      ));
      final container = ProviderContainer(overrides: [
        downloadDatabaseProvider.overrideWith((ref) async => database),
        unifiedDownloadJobServiceProvider.overrideWith((ref) => null),
        sourceRecordsProvider.overrideWith(() => _Records(records)),
        // Hidden while the app is locked: no source is built.
        mediaSourceProvider(source).overrideWithValue(null),
      ]);
      addTearDown(container.dispose);
      // The app has the records loaded long before a sweep matters.
      if (loaded) await container.read(sourceRecordsProvider.future);
      await container.read(downloadManagerProvider.future);

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline)) {
        final task = database.getTask('hidden-dl')!;
        if (task.status == 'failed' || task.lastProgressAt != seededAt) {
          // Let a park finish writing.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return database.getTask('hidden-dl')!;
    }

    test('is parked while its account is still stored', () async {
      final task =
          await sweep(() async => SourceSnapshot(accounts: [plexRecord()]));
      expect(task.status, 'interrupted');
      expect(task.recoveryAttempts, 0);
    });

    test('is parked while the stored sources have not loaded', () async {
      final never = Completer<SourceSnapshot>();
      final task = await sweep(() => never.future, loaded: false);
      expect(task.status, 'interrupted');
    });

    test('fails for good once its account is gone', () async {
      final task = await sweep(() async => SourceSnapshot.empty);
      expect(task.status, 'failed', reason: '${task.error}');
    });
  });
}

class _Records extends SourceRecordsNotifier {
  _Records(this._load);
  final Future<SourceSnapshot> Function() _load;

  @override
  Future<SourceSnapshot> build() => _load();
}
