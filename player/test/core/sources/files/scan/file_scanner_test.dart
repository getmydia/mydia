import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/connection/app_foreground.dart';
import 'package:player/core/sources/files/backend/webdav_backend.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/local_path_backend.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/scan/file_scanner.dart';

import '../fake_backend.dart';
import '../fake_media_names.dart';

void main() {
  late Directory dir;
  late FileLibraryIndex index;
  late FakeMediaNames names;
  var n = 0;

  const root = LibraryRoot(
    id: 'r1',
    path: '/lib',
    kind: FilesLibraryKind.mixed,
    title: 'Lib',
  );
  final t0 = DateTime.fromMillisecondsSinceEpoch(1800000000000);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('file_scanner_test');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map<dynamic, dynamic>>('scan_${n++}');
    index = FileLibraryIndex(box, accountId: 'acc');
    names = FakeMediaNames();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  FileScanner scanner(
    FakeBackend b, {
    DateTime Function()? now,
    AppForeground? foreground,
  }) =>
      FileScanner(
        backend: b,
        names: names,
        index: index,
        now: now,
        foreground: foreground,
      );

  group('the app leaving the foreground mid-walk', () {
    // iOS freezes a backgrounded app; the request in flight then times out
    // the moment it comes back, before the resume is even reported.
    test('a_folder_that_failed_while_away_is_read_again_on_return', () async {
      final app = AppForeground();
      final b = _SuspendingBackend(
          {
            '/lib/A.mkv': 1,
            '/lib/sub/B.mkv': 1,
            '/lib/sub/deeper/C.mkv': 1,
          },
          app: app,
          suspendOn: {'/lib/sub': 1});

      var finished = false;
      final scan = scanner(b, foreground: app)
          .scan(root)
          .whenComplete(() => finished = true);
      await pumpEventQueue();
      expect(finished, isFalse, reason: 'waits for the app to come back');
      expect(index.files(), isEmpty);

      app.onLifecycle(AppLifecycleState.resumed);
      final delta = await scan;

      expect([for (final f in delta.added) f.path],
          unorderedEquals(['A.mkv', 'sub/B.mkv', 'sub/deeper/C.mkv']));
      // Picked up at the folder that failed, not walked again from the top.
      expect(b.listed.where((d) => d == '/lib'), hasLength(1));
      expect(b.listed.where((d) => d == '/lib/sub'), hasLength(2));
    });

    test('a_folder_that_fails_in_the_foreground_still_fails_the_scan',
        () async {
      final app = AppForeground();
      final b = FakeBackend({'/lib/A.mkv': 1, '/lib/sub/B.mkv': 1});
      b.failures['/lib/sub'] = const BackendUnreachable('timed out');
      await expectLater(scanner(b, foreground: app).scan(root),
          throwsA(isA<BackendUnreachable>()));
      expect(b.listed.where((d) => d == '/lib/sub'), hasLength(1));
      expect(index.files(), isEmpty);
    });

    test('a_folder_that_fails_after_every_return_ends_the_scan', () async {
      final app = AppForeground();
      final b = _SuspendingBackend({'/lib/A.mkv': 1, '/lib/sub/B.mkv': 1},
          app: app, suspendOn: {'/lib/sub': 100}, resumeAfter: true);
      await expectLater(scanner(b, foreground: app).scan(root),
          throwsA(isA<BackendUnreachable>()));
      expect(b.listed.where((d) => d == '/lib/sub'),
          hasLength(FileScanner.maxReadsAcrossSuspensions));
    });

    test('a_refusal_while_away_is_not_retried', () async {
      final app = AppForeground()..onLifecycle(AppLifecycleState.paused);
      final b = FakeBackend({'/lib/A.mkv': 1, '/lib/locked/B.mkv': 1});
      b.failures['/lib/locked'] = const BackendUnauthorized('HTTP 403');
      final delta = await scanner(b, foreground: app).scan(root);
      expect([for (final f in delta.added) f.path], ['A.mkv']);
      expect(b.listed.where((d) => d == '/lib/locked'), hasLength(1));
    });
  });

  test('the_walk_reports_each_folder_it_reads', () async {
    final b = FakeBackend({
      '/lib/A.mkv': 1,
      '/lib/x/B.mkv': 1,
      '/lib/y/C.mkv': 1,
    });
    final folders = <int>[];
    await scanner(b).scan(root, onFolderRead: folders.add);
    expect(folders, [1, 2, 3]);
  });

  test('first_scan_adds_videos_and_attaches_sidecars', () async {
    final b = FakeBackend({
      '/lib/A/Movie.mkv': 100,
      '/lib/A/Movie.en.srt': 5,
      '/lib/A/Other.srt': 5,
      '/lib/A/notes.txt': 1,
    });
    final delta = await scanner(b).scan(root);
    expect(delta.added, hasLength(1));
    final f = delta.added.single;
    expect(f.path, 'A/Movie.mkv');
    expect(f.key, fileKeyFor('r1', 'A/Movie.mkv'));
    expect(f.sidecars, ['A/Movie.en.srt']);
    expect(f.parsed?.title, 'Movie');
    expect(index.files(), hasLength(1));
    expect(names.parsedPaths, ['/lib/A/Movie.mkv']);
  });

  test('unparsed_names_are_indexed_with_null_parsed', () async {
    final b = FakeBackend({'/lib/(2001).mkv': 1});
    final delta = await scanner(b).scan(root);
    expect(delta.added.single.parsed, isNull);
  });

  test('unchanged_files_are_not_reparsed', () async {
    final b = FakeBackend({'/lib/A.mkv': 1, '/lib/B.mkv': 2});
    await scanner(b).scan(root);
    final delta = await scanner(b).scan(root);
    expect(delta.isEmpty, isTrue);
    expect(names.parsedPaths, hasLength(2));
  });

  test('changed_size_or_mtime_is_reparsed', () async {
    final b = FakeBackend({'/lib/A.mkv': 1, '/lib/B.mkv': 2});
    var clock = t0;
    await scanner(b, now: () => clock).scan(root);
    final first = index.files().values.first.firstSeen;
    clock = t0.add(const Duration(days: 1));
    b.setFile('/lib/A.mkv', 9);
    b.setFile('/lib/B.mkv', 2, modified: t0);
    final delta = await scanner(b, now: () => clock).scan(root);
    expect(delta.added, isEmpty);
    expect(delta.changed, hasLength(2));
    expect(names.parsedPaths, hasLength(4));
    expect(delta.changed.every((f) => f.firstSeen == first), isTrue);
  });

  test('a_root_whose_kind_changes_is_read_again', () async {
    final b = FakeBackend({'/lib/A.mkv': 1});
    await scanner(b).scan(root);
    final delta = await scanner(b).scan(const LibraryRoot(
      id: 'r1',
      path: '/lib',
      kind: FilesLibraryKind.series,
      title: 'Lib',
    ));
    expect(delta.changed, hasLength(1));
    expect(delta.changed.single.parsedAs, FilesLibraryKind.series);
    expect(names.parsedPaths, hasLength(2));
    expect(
      index.files().values.single.parsedAs,
      FilesLibraryKind.series,
    );
  });

  test('a_root_removed_while_it_is_walked_gets_no_files_back', () async {
    await index.putRoot(root);
    final b =
        _RemovesRootOnList({'/lib/A.mkv': 1}, () => index.removeRoot(root.id));
    final delta = await scanner(b).scan(root);
    expect(delta.isEmpty, isTrue);
    expect(index.files(), isEmpty);
  });

  test('missing_files_are_reported_removed', () async {
    final b = FakeBackend({'/lib/A.mkv': 1, '/lib/B.mkv': 2});
    await scanner(b).scan(root);
    b.removeFile('/lib/B.mkv');
    final delta = await scanner(b).scan(root);
    expect(delta.removedKeys, [fileKeyFor('r1', 'B.mkv')]);
    expect(index.files(), hasLength(1));
  });

  test('hidden_and_nas_metadata_dirs_are_skipped', () async {
    final b = FakeBackend({
      '/lib/.hidden.mkv': 1,
      '/lib/.trash/X.mkv': 1,
      '/lib/@eaDir/Y.mkv': 1,
      '/lib/#recycle/Z.mkv': 1,
      '/lib/ok/W.MKV': 1,
    });
    final delta = await scanner(b).scan(root);
    expect([for (final f in delta.added) f.path], ['ok/W.MKV']);
  });

  test('backend_failure_leaves_the_index_untouched', () async {
    final b = FakeBackend({'/lib/A.mkv': 1, '/lib/sub/B.mkv': 1});
    await scanner(b).scan(root);
    b.setFile('/lib/C.mkv', 1);
    b.removeFile('/lib/A.mkv');
    b.failures['/lib/sub'] = const BackendUnreachable('down');
    await expectLater(
        scanner(b).scan(root), throwsA(isA<BackendUnreachable>()));
    expect(index.files().values.map((f) => f.path).toSet(), {
      'A.mkv',
      'sub/B.mkv',
    });
  });

  for (final (name, failure) in const [
    ('refused', BackendPermissionLost('/lib/locked')),
    ('unauthorized', BackendUnauthorized('HTTP 403')),
    ('gone', BackendNotFound('/lib/locked')),
  ]) {
    test('a_${name}_subfolder_is_skipped_and_its_files_kept', () async {
      final b = FakeBackend({
        '/lib/A.mkv': 1,
        '/lib/locked/B.mkv': 1,
        '/lib/locked/deep/C.mkv': 1,
        '/lib/open/D.mkv': 1,
      });
      await scanner(b).scan(root);
      b.failures['/lib/locked'] = failure;
      b.setFile('/lib/open/E.mkv', 1);
      b.removeFile('/lib/A.mkv');

      final delta = await scanner(b).scan(root);

      expect(delta.added.map((f) => f.path), ['open/E.mkv']);
      expect(delta.removedKeys, [fileKeyFor('r1', 'A.mkv')]);
      expect(delta.skippedPaths, ['locked']);
      expect(index.files().values.map((f) => f.path).toSet(), {
        'locked/B.mkv',
        'locked/deep/C.mkv',
        'open/D.mkv',
        'open/E.mkv',
      });
    });
  }

  group('webdav entries the server refuses', () {
    const davRoot = LibraryRoot(
      id: 'rd',
      path: '/media',
      kind: FilesLibraryKind.mixed,
      title: 'Share',
    );

    /// Serves `PROPFIND` from [listings], by request path.
    FileScanner davScanner(Map<String, String> listings) => FileScanner(
          backend: WebDavBackend(
            base: Uri.parse('https://dav.example.test/media/'),
            user: 'u',
            password: 'p',
            client: MockClient((r) async {
              final body = listings[r.url.path];
              return body == null
                  ? http.Response('', 404)
                  : http.Response(body, 207);
            }),
          ),
          names: names,
          index: index,
        );

    Set<String> indexed() => index.files().values.map((f) => f.path).toSet();

    final readable = {
      '/media/':
          _ms([_dir('/media/'), _dir('/media/Show/'), _file('/media/A.mkv')]),
      '/media/Show/': _ms([
        _dir('/media/Show/'),
        _file('/media/Show/Show S01E01.mkv'),
        _file('/media/Show/Show S01E02.mkv'),
      ]),
    };

    test('an_indexed_file_later_refused_is_kept_and_reported', () async {
      await davScanner(readable).scan(davRoot);
      expect(indexed(), hasLength(3));

      final delta = await davScanner({
        ...readable,
        '/media/Show/': _ms([
          _dir('/media/Show/'),
          _file('/media/Show/Show S01E01.mkv'),
          _denied('/media/Show/Show S01E02.mkv'),
        ]),
      }).scan(davRoot);

      expect(delta.removedKeys, isEmpty);
      expect(delta.skippedPaths, ['Show/Show S01E02.mkv']);
      expect(indexed(), contains('Show/Show S01E02.mkv'));
    });

    for (final href in ['/media/Show/', '/media/Show']) {
      test('a_refused_folder_entry_keeps_its_subtree ($href)', () async {
        await davScanner(readable).scan(davRoot);

        final delta = await davScanner({
          '/media/': _ms([
            _dir('/media/'),
            _denied(href),
            _file('/media/A.mkv'),
          ]),
        }).scan(davRoot);

        expect(delta.removedKeys, isEmpty);
        expect(delta.skippedPaths, ['Show']);
        expect(indexed(), {
          'A.mkv',
          'Show/Show S01E01.mkv',
          'Show/Show S01E02.mkv',
        });
      });
    }
  });

  test('a_root_that_cannot_be_read_still_fails_the_scan', () async {
    final b = FakeBackend({'/lib/A.mkv': 1});
    await scanner(b).scan(root);
    b.setFile('/lib/B.mkv', 1);
    b.failures['/lib'] = const BackendPermissionLost('/lib');
    await expectLater(
        scanner(b).scan(root), throwsA(isA<BackendPermissionLost>()));
    expect(index.files().values.map((f) => f.path), ['A.mkv']);
  });

  test('a_real_folder_without_permissions_is_skipped', () async {
    final tmp = await Directory.systemTemp.createTemp('scan_locked');
    final locked = Directory('${tmp.path}/locked')..createSync();
    File('${tmp.path}/Open Film (2001).mkv').writeAsBytesSync([1]);
    File('${locked.path}/Hidden Film (2002).mkv').writeAsBytesSync([1]);
    addTearDown(() async {
      await Process.run('chmod', ['-R', 'u+rwx', tmp.path]);
      await tmp.delete(recursive: true);
    });
    final chmod = await Process.run('chmod', ['000', locked.path]);
    expect(chmod.exitCode, 0,
        reason: 'could not lock the folder: ${chmod.stderr}');
    final local = LibraryRoot(
      id: 'rl',
      path: tmp.path,
      kind: FilesLibraryKind.movies,
      title: 'Local',
    );
    final delta = await FileScanner(
      backend: LocalPathBackend(),
      names: names,
      index: index,
    ).scan(local);
    expect(delta.added.map((f) => f.path), ['Open Film (2001).mkv']);
    expect(delta.skippedPaths, ['locked']);
  }, skip: Platform.isWindows || _runningAsRoot());

  test('cyclic_listing_terminates_with_files_found_once', () async {
    final b = _CyclicBackend({'/lib/A/Movie.mkv': 1});
    final delta = await scanner(b).scan(root);
    expect([for (final f in delta.added) f.path], ['A/Movie.mkv']);
  });

  group('local_folder_links', () {
    late Directory tmp;
    late LibraryRoot local;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('scanner_links_');
      // Resolved, so the root is where its links lead (macOS keeps temp
      // folders behind /var -> /private/var).
      final base = tmp.resolveSymbolicLinksSync();
      Directory('$base/lib/real').createSync(recursive: true);
      File('$base/lib/real/Copper Valley (2018).mkv').writeAsBytesSync([1]);
      Directory('$base/outside').createSync();
      File('$base/outside/Harbor Lights (2020).mkv').writeAsBytesSync([1]);
      File('$base/lib/Glass Orchard S01E01.mkv').writeAsBytesSync([1]);
      Link('$base/lib/alias').createSync('$base/lib/real');
      Link('$base/lib/elsewhere').createSync('$base/outside');
      Link('$base/lib/real/up').createSync('$base/lib');
      local = LibraryRoot(
        id: 'r1',
        path: '$base/lib',
        kind: FilesLibraryKind.mixed,
        title: 'Lib',
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a_linked_directory_is_walked_and_its_files_found_once', () async {
      final delta = await FileScanner(
              backend: LocalPathBackend(), names: names, index: index)
          .scan(local);
      final paths = [for (final f in delta.added) f.path];
      expect(paths, hasLength(3));
      expect(paths, contains('Glass Orchard S01E01.mkv'));
      expect(paths, contains('elsewhere/Harbor Lights (2020).mkv'));
      expect(paths.where((p) => p.endsWith('/Copper Valley (2018).mkv')),
          hasLength(1));
    });

    test('a_root_reached_through_a_link_is_walked_once', () async {
      Link('${tmp.path}/via').createSync(local.path);
      final delta = await FileScanner(
              backend: LocalPathBackend(), names: names, index: index)
          .scan(LibraryRoot(
              id: 'r1',
              path: '${tmp.path}/via',
              kind: FilesLibraryKind.mixed,
              title: 'Lib'));
      // Without the root's own identity, `real/up` would walk it again and
      // find the top-level episode a second time.
      final paths = [for (final f in delta.added) f.path];
      expect(paths, hasLength(3));
      expect(paths, contains('Glass Orchard S01E01.mkv'));
    });
  });

  test('directories_deeper_than_32_levels_are_skipped', () async {
    final deep = [for (var i = 0; i < 40; i++) 'd$i'].join('/');
    final b = FakeBackend({'/lib/top.mkv': 1, '/lib/$deep/deep.mkv': 1});
    final delta = await scanner(b).scan(root);
    expect([for (final f in delta.added) f.path], ['top.mkv']);
  });

  test('progress_reports_done_of_total', () async {
    final b = FakeBackend({
      for (var i = 0; i < 450; i++) '/lib/Film $i.mkv': i,
    });
    final calls = <(int, int)>[];
    await scanner(b).scan(root, onProgress: (d, t) => calls.add((d, t)));
    expect(calls.every((c) => c.$2 == 450), isTrue);
    expect(calls.last, (450, 450));
    expect(calls.length, greaterThanOrEqualTo(3));
    final dones = [for (final c in calls) c.$1];
    expect(dones, orderedEquals([...dones]..sort()));
  });
}

/// Leaves the foreground while listing a folder in [suspendOn], as iOS
/// suspending the app mid-request, and fails that listing the way the
/// overdue timeout does. With [resumeAfter], the app comes back right after.
class _SuspendingBackend extends FakeBackend {
  _SuspendingBackend(
    super.files, {
    required this.app,
    required Map<String, int> suspendOn,
    this.resumeAfter = false,
  }) : _suspendOn = Map.of(suspendOn);

  final AppForeground app;
  final Map<String, int> _suspendOn;
  final bool resumeAfter;

  @override
  Future<List<FileEntry>> list(String dir) async {
    final left = _suspendOn[dir] ?? 0;
    if (left == 0) return super.list(dir);
    _suspendOn[dir] = left - 1;
    listed.add(dir);
    app.onLifecycle(AppLifecycleState.hidden);
    if (resumeAfter) {
      scheduleMicrotask(() => app.onLifecycle(AppLifecycleState.resumed));
    }
    throw const BackendUnreachable('timed out');
  }
}

/// Lists an extra entry in `/lib/A` that points back at `/lib`, and one that
/// points at `/lib/A` itself.
class _CyclicBackend extends FakeBackend {
  _CyclicBackend(super.files);

  @override
  Future<List<FileEntry>> list(String dir) async {
    final entries = await super.list(dir);
    if (dir != '/lib/A') return entries;
    final t = FakeBackend.defaultModified;
    return [
      ...entries,
      FileEntry(path: '/lib', name: 'up', isDir: true, size: 0, modified: t),
      FileEntry(
        path: '/lib/A',
        name: 'self',
        isDir: true,
        size: 0,
        modified: t,
      ),
    ];
  }
}

String _ms(List<String> responses) =>
    '<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">'
    '${responses.join()}</D:multistatus>';

String _dir(String href) => '<D:response><D:href>$href</D:href>'
    '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype>'
    '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';

String _file(String href) => '<D:response><D:href>$href</D:href>'
    '<D:propstat><D:prop><D:resourcetype/>'
    '<D:getcontentlength>10</D:getcontentlength>'
    '<D:getlastmodified>Sun, 01 Nov 2026 12:00:00 GMT</D:getlastmodified>'
    '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';

/// Refused, with no resourcetype: nothing says whether it is a folder.
String _denied(String href) => '<D:response><D:href>$href</D:href>'
    '<D:propstat><D:prop/><D:status>HTTP/1.1 403 Forbidden</D:status>'
    '</D:propstat></D:response>';

/// Root reads a chmod 000 folder anyway, so the permission tests mean
/// nothing under uid 0.
bool _runningAsRoot() {
  if (Platform.isWindows) return false;
  final id = Process.runSync('id', ['-u']);
  return id.exitCode == 0 && (id.stdout as String).trim() == '0';
}

/// Runs [onList] (the viewer removing the root) during the walk.
class _RemovesRootOnList extends FakeBackend {
  _RemovesRootOnList(super.files, this.onList);

  final Future<void> Function() onList;

  @override
  Future<List<FileEntry>> list(String dir) async {
    await onList();
    return super.list(dir);
  }
}
