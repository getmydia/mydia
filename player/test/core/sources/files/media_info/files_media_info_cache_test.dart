import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/player/mpv_probe_mapping.dart';
import 'package:player/core/sources/files/index/index_records.dart';
import 'package:player/core/sources/files/media_info/files_media_info_cache.dart';

void main() {
  late Directory dir;
  late Box<Map<dynamic, dynamic>> box;
  late FilesMediaInfoCache cache;
  var n = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('files_media_info_test');
    Hive.init(dir.path);
    box = await Hive.openBox<Map<dynamic, dynamic>>('files_media_info_${n++}');
    cache = FilesMediaInfoCache(box);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  final t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

  IndexedFile file(String key, {int size = 10, DateTime? modified}) =>
      IndexedFile(
        key: key,
        rootId: 'r1',
        path: '$key.mkv',
        size: size,
        modified: modified ?? t,
        firstSeen: t,
      );

  const result = ProbeResult(container: 'matroska', durationSeconds: 61.5);

  test('get returns what put stored', () async {
    await cache.put('a', file('k1'), result);
    final got = cache.get('a', file('k1'));
    expect(got?.container, 'matroska');
    expect(got?.durationSeconds, 61.5);
  });

  test('a size change is a miss', () async {
    await cache.put('a', file('k1'), result);
    expect(cache.get('a', file('k1', size: 11)), isNull);
  });

  test('an mtime change alone is a miss', () async {
    await cache.put('a', file('k1'), result);
    final later = t.add(const Duration(seconds: 1));
    expect(cache.get('a', file('k1', modified: later)), isNull);
  });

  test('a corrupt stored value is a miss', () async {
    await box.put('a|k1', {
      'size': 10,
      'modified': t.millisecondsSinceEpoch,
      'result': 'x',
    });
    expect(cache.get('a', file('k1')), isNull);
  });

  test('sweep drops keys no longer indexed and keeps the rest', () async {
    await cache.put('a', file('k1'), result);
    await cache.put('a', file('k2'), result);
    await cache.put('b', file('k3'), result);
    await cache.sweep('a', {'k1'});
    expect(cache.get('a', file('k1')), isNotNull);
    expect(cache.get('a', file('k2')), isNull);
    expect(cache.get('b', file('k3')), isNotNull);
  });

  test('clearAccount drops only that account', () async {
    await cache.put('a', file('k1'), result);
    await cache.put('ab', file('k1'), result);
    await cache.clearAccount('a');
    expect(cache.get('a', file('k1')), isNull);
    expect(cache.get('ab', file('k1')), isNotNull);
  });
}
