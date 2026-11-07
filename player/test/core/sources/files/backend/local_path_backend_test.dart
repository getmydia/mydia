import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/local_path_backend.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('local_backend_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('lists_one_level_with_size_and_mtime', () async {
    File('${tmp.path}/a.mkv').writeAsBytesSync([1, 2, 3]);
    Directory('${tmp.path}/sub').createSync();
    File('${tmp.path}/sub/deep.mkv').writeAsBytesSync([1]);

    final entries = await LocalPathBackend().list(tmp.path);
    entries.sort((a, b) => a.name.compareTo(b.name));

    expect(entries.map((e) => e.name), ['a.mkv', 'sub']);
    expect(entries[0].isDir, isFalse);
    expect(entries[0].size, 3);
    expect(entries[0].modified.year, greaterThan(2000));
    expect(entries[1].isDir, isTrue);
    expect(entries[1].size, 0);
  });

  test('directory_links_list_as_directories_with_their_resolved_identity',
      () async {
    File('${tmp.path}/a.mkv').writeAsBytesSync([1]);
    Directory('${tmp.path}/sub').createSync();
    Link('${tmp.path}/sub/loop').createSync(tmp.path);
    Link('${tmp.path}/alias.mkv').createSync('${tmp.path}/a.mkv');
    Link('${tmp.path}/broken').createSync('${tmp.path}/gone');

    final sub = await LocalPathBackend().list('${tmp.path}/sub');
    expect(sub.single.name, 'loop');
    expect(sub.single.isDir, isTrue);
    expect(sub.single.path, '${tmp.path}/sub/loop');
    expect(sub.single.identity, tmp.resolveSymbolicLinksSync());
    final top = await LocalPathBackend().list(tmp.path);
    expect(top.map((e) => e.name).toSet(), {'a.mkv', 'sub', 'alias.mkv'});
    expect(top.firstWhere((e) => e.name == 'alias.mkv').identity, isNull);
  });

  test('windows_paths_use_forward_slashes', () {
    expect(
        portableLocalPath(r'C:\Media\Films\Copper Valley.mkv', windows: true),
        'C:/Media/Films/Copper Valley.mkv');
    expect(portableLocalPath(r'\\nas\share\Films', windows: true),
        '//nas/share/Films');
    // Elsewhere a backslash is part of a file name.
    expect(portableLocalPath(r'/media/odd\name.mkv', windows: false),
        r'/media/odd\name.mkv');
  });

  test('os_errors_map_by_platform', () {
    BackendFailure win(int code) =>
        mapLocalFailure(code, 'failed', 'C:/x', windows: true);
    BackendFailure posix(int code) =>
        mapLocalFailure(code, 'failed', '/x', windows: false);
    expect(win(5), isA<BackendPermissionLost>());
    expect(win(2), isA<BackendNotFound>());
    expect(win(3), isA<BackendNotFound>());
    expect(win(21), isA<BackendUnreachable>());
    expect(posix(13), isA<BackendPermissionLost>());
    expect(posix(1), isA<BackendPermissionLost>());
    expect(posix(2), isA<BackendNotFound>());
    // EIO is not a refusal.
    expect(posix(5), isA<BackendUnreachable>());
    expect(
      mapLocalFailure(3, 'failed', 'C:/x',
          windows: true, missing: const BackendUnreachable()),
      isA<BackendUnreachable>(),
    );
  });

  test('list_of_missing_dir_throws_not_found', () {
    expect(
      LocalPathBackend().list('${tmp.path}/nope'),
      throwsA(isA<BackendNotFound>()),
    );
  });

  test('stat_of_missing_file_is_null', () async {
    expect(await LocalPathBackend().stat('${tmp.path}/nope.mkv'), isNull);
  });

  test('playable_is_the_path_with_no_headers', () async {
    final p = await LocalPathBackend().playable('${tmp.path}/a.mkv');
    expect(p.url, '${tmp.path}/a.mkv');
    expect(p.headers, isEmpty);
  });

  test('probe_of_missing_root_throws_unreachable', () {
    expect(
      LocalPathBackend(root: '${tmp.path}/gone').probe(),
      throwsA(isA<BackendUnreachable>()),
    );
  });

  test('probe_without_root_or_with_existing_root_succeeds', () async {
    await LocalPathBackend().probe();
    await LocalPathBackend(root: tmp.path).probe();
  });
}
