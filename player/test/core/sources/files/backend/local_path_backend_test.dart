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
