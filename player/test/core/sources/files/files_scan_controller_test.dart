import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/connection/connection_refresh_bus.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/no_downloads.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final now = DateTime.utc(2026, 6, 1, 12);
  var clock = now;
  late FilesFixture f;
  late FakeBackend backend;

  Future<ProviderContainer> container({
    MediaNames? names,
    bool realBackend = false,
  }) async {
    final store = InMemorySourceStore();
    await store.putAccount(filesLocalRecord);
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      filesIndexBoxProvider.overrideWithValue(f.box),
      filesProgressStoreProvider.overrideWithValue(f.progress),
      mediaNamesProvider.overrideWithValue(names ?? FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      if (!realBackend)
        filesBackendBuilderProvider.overrideWithValue((ref, source) => backend),
      filesClockProvider.overrideWithValue(() => clock),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    return c;
  }

  setUp(() async {
    clock = now;
    f = await FilesFixture.create(seed: false);
    await f.index.putRoot(const LibraryRoot(
      id: 'rm',
      path: '/media/films',
      kind: FilesLibraryKind.movies,
      title: 'Films',
    ));
    backend = FakeBackend({
      '/media/films/Amber Tide (2019).mkv': 10,
      '/media/films/Low Orbit (2022).mkv': 20,
    });
  });

  test('rescan_on_open_only_when_older_than_six_hours', () async {
    // Shares the index the container builds, so the scan writes are seen.
    Future<FileLibraryIndex> open(DateTime? lastScan) async {
      backend.listed.clear();
      final c = await container();
      final index = c.read(filesIndexProvider(filesLocalSource.account.id));
      if (lastScan != null) await index.setLastScanAt(lastScan);
      expect(c.read(mediaSourceProvider(filesLocalSource.id)),
          isA<FilesMediaSource>());
      await _settle();
      return index;
    }

    await open(now.subtract(const Duration(hours: 2)));
    expect(backend.listed, isEmpty);

    final index = await open(now.subtract(const Duration(hours: 7)));
    expect(backend.listed, ['/media/films']);
    expect(index.lastScanAt(), now);
    expect(index.files(), hasLength(2));
  });

  test('a_never_scanned_library_scans_on_open', () async {
    final c = await container();
    c.read(mediaSourceProvider(filesLocalSource.id));
    await _settle();
    expect(backend.listed, ['/media/films']);
  });

  test('scan_progress_is_exposed', () async {
    await f.index.setLastScanAt(now);
    final c = await container();
    final id = filesLocalSource.id;
    c.read(mediaSourceProvider(id));
    final states = <ScanState>[];
    c.listen(filesScanProvider(id), (_, s) => states.add(s),
        fireImmediately: true);
    await c.read(filesScanProvider(id).notifier).rescan();
    expect(states.first.running, isFalse);
    expect(states.any((s) => s.running && s.total == 2 && s.done == 2), isTrue);
    expect(states.last.running, isFalse);
    expect((states.last.done, states.last.total), (2, 2));
    expect(states.last.error, isNull);
  });

  test('a_root_that_cannot_be_read_is_reported_and_others_still_scan',
      () async {
    await f.index.putRoot(const LibraryRoot(
      id: 'rgone',
      path: '/media/gone',
      kind: FilesLibraryKind.movies,
      title: 'Gone',
    ));
    await f.index.setLastScanAt(now);
    final c = await container();
    final id = filesLocalSource.id;
    c.read(mediaSourceProvider(id));
    final media = c.read(mediaSourceProvider(id))!;
    await _settle();
    expect(media.connection, SourceConnectionStatus.local);
    await c.read(filesScanProvider(id).notifier).rescan();
    final state = c.read(filesScanProvider(id));
    expect(state.error, isA<BackendNotFound>());
    expect(state.total, 2);
    expect(media.connection, SourceConnectionStatus.unreachable);
  });

  test('a_run_where_every_root_fails_keeps_the_last_scan_time', () async {
    final earlier = now.subtract(const Duration(hours: 1));
    await f.index.setLastScanAt(earlier);
    backend.failures['/media/films'] = const BackendNotFound('unplugged');
    final c = await container();
    final id = filesLocalSource.id;
    c.read(mediaSourceProvider(id));
    final index = c.read(filesIndexProvider(filesLocalSource.account.id));
    await c.read(filesScanProvider(id).notifier).rescan();
    expect(c.read(filesScanProvider(id)).error, isA<BackendNotFound>());
    expect(index.lastScanAt()?.toUtc(), earlier);

    // Once one root reads again, the scan counts.
    backend.failures.clear();
    await c.read(filesScanProvider(id).notifier).rescan();
    expect(index.lastScanAt()?.toUtc(), now);
  });

  test('storage_that_failed_to_open_leaves_files_sources_out', () async {
    final store = InMemorySourceStore();
    await store.putAccount(filesLocalRecord);
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      filesIndexBoxProvider
          .overrideWith((ref) => throw StateError('box not open')),
      filesProgressStoreProvider.overrideWithValue(f.progress),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    expect(c.read(sourcesProvider).map((s) => s.id), [filesLocalSource.id]);
    expect(c.read(mediaSourceProvider(filesLocalSource.id)), isNull);
    expect(c.read(allServersSourcesProvider), isEmpty);
  });

  test('forgot_pin_removes_a_locked_files_account_with_its_index', () async {
    final store = InMemorySourceStore();
    await store.putAccount(filesLocalRecord.copyWith(
        serverLocks: {filesLocalSource.server.id: SourceLock.hidden}));
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      filesIndexBoxProvider.overrideWithValue(f.box),
      filesProgressStoreProvider.overrideWithValue(f.progress),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    await f.addFiles(['Amber Tide (2019).mkv'], rootId: 'rm');

    await c.read(sourceRecordsProvider.notifier).removeLockedAccounts();

    expect((await store.load()).accounts, isEmpty);
    final reopened =
        FileLibraryIndex(f.box, accountId: filesLocalSource.account.id);
    expect(reopened.roots(), isEmpty);
    expect(reopened.files(), isEmpty);
  });

  test('a_resume_past_the_interval_scans', () async {
    await f.index.setLastScanAt(now);
    final c = await container();
    c.read(mediaSourceProvider(filesLocalSource.id));
    await _settle();
    expect(backend.listed, isEmpty);

    c.read(connectionRefreshBusProvider).ping(ConnectionRefreshReason.resume);
    await _settle();
    expect(backend.listed, isEmpty);

    clock = now.add(const Duration(hours: 7));
    c.read(connectionRefreshBusProvider).ping(ConnectionRefreshReason.resume);
    await _settle();
    expect(backend.listed, ['/media/films']);
  });

  test('a_rescan_asked_for_during_a_scan_runs_again_after_it', () async {
    final gated = _GatedBackend({
      '/media/films/Amber Tide (2019).mkv': 10,
      '/media/new/Low Orbit (2022).mkv': 20,
    });
    backend = gated;
    await f.index.setLastScanAt(now);
    final c = await container();
    final id = filesLocalSource.id;
    c.read(mediaSourceProvider(id));
    final scans = c.read(filesScanProvider(id).notifier);

    // The container's own index, which the scans read.
    final index = c.read(filesIndexProvider(filesLocalSource.account.id));
    final first = scans.rescan();
    await _settle();
    await index.putRoot(const LibraryRoot(
      id: 'rn',
      path: '/media/new',
      kind: FilesLibraryKind.movies,
      title: 'New',
    ));
    final second = scans.rescan();
    final third = scans.rescan();
    gated.gate.complete();
    await Future.wait([first, second, third]);

    expect(gated.listed.where((d) => d == '/media/films'), hasLength(2));
    expect(gated.listed.where((d) => d == '/media/new'), hasLength(1));
    expect(index.files(), hasLength(2));
  });

  test('a_scan_that_throws_still_finishes', () async {
    await f.index.setLastScanAt(now);
    final c = await container(names: _ThrowingNames());
    final id = filesLocalSource.id;
    c.read(mediaSourceProvider(id));
    await c.read(filesScanProvider(id).notifier).rescan();
    final state = c.read(filesScanProvider(id));
    expect(state.running, isFalse);
    expect(state.error, isA<Exception>());
  });

  group('local folders through the real backend', () {
    late Directory tmp;
    setUp(() async {
      // Only the roots each test adds: the fake backend's root is not on disk.
      await f.index.removeRoot('rm');
      tmp = await Directory.systemTemp.createTemp('files_local_roots');
      addTearDown(() async {
        await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
        await tmp.delete(recursive: true);
      });
    });

    Future<FilesMediaSource> open(ProviderContainer c) async {
      final media =
          c.read(mediaSourceProvider(filesLocalSource.id))! as FilesMediaSource;
      await _settle();
      return media;
    }

    test('a_missing_root_is_unreachable_and_still_browses', () async {
      final gone = '${tmp.path}/unplugged';
      await f.index.putRoot(LibraryRoot(
        id: 'rgone',
        path: gone,
        kind: FilesLibraryKind.movies,
        title: 'Gone',
      ));
      await f.addFiles(['Amber Tide (2019).mkv'], rootId: 'rgone');
      await f.index.setLastScanAt(now);
      final c = await container(realBackend: true);
      final media = await open(c);
      expect(media.backend, isA<LocalFoldersBackend>());
      expect(media.connection, SourceConnectionStatus.unreachable);
      expect(c.read(thirdPartySourcesProvider).single.account.needsReauth,
          isFalse);
      final page = await media.browse(
          LibraryRef(sourceId: filesLocalSource.id, id: 'rgone'),
          const BrowseQuery());
      expect(page.items.single.title, 'Amber Tide');
    });

    test('a_root_that_refuses_access_flags_sign_in', () async {
      final locked = Directory('${tmp.path}/locked')..createSync();
      await Process.run('chmod', ['000', locked.path]);
      await f.index.putRoot(LibraryRoot(
        id: 'rlocked',
        path: locked.path,
        kind: FilesLibraryKind.movies,
        title: 'Locked',
      ));
      await f.index.setLastScanAt(now);
      final c = await container(realBackend: true);
      final media = await open(c);
      expect(media.connection, SourceConnectionStatus.unreachable);
      expect(
          c.read(thirdPartySourcesProvider).single.account.needsReauth, isTrue);
    }, skip: Platform.isWindows);

    test('present_roots_are_local', () async {
      await f.index.putRoot(LibraryRoot(
        id: 'rhere',
        path: tmp.path,
        kind: FilesLibraryKind.movies,
        title: 'Here',
      ));
      await f.index.setLastScanAt(now);
      final c = await container(realBackend: true);
      final media = await open(c);
      expect(media.connection, SourceConnectionStatus.local);
    });
  });
}

/// Holds every listing until [gate] completes.
class _GatedBackend extends FakeBackend {
  _GatedBackend(super.files);

  final gate = Completer<void>();

  @override
  Future<List<FileEntry>> list(String dir) async {
    await gate.future;
    return super.list(dir);
  }
}

class _ThrowingNames extends FakeMediaNames {
  @override
  List<ParsedName> parseBatch(
    String root,
    List<String> paths,
    FilesLibraryKind kind,
  ) =>
      throw Exception('parser crashed');
}
