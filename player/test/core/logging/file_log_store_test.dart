@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/logging/log_platform_io.dart';
import 'package:player/core/logging/log_record.dart';
import 'package:player/core/logging/log_store.dart';

LogRecord _record(int t) => LogRecord(
      time: DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
      level: LogLevel.info,
      tag: 'Test',
      message: 'line',
      sessionId: 'sess0001',
    );

int _lineBytes() => utf8.encode(_record(1).toNdjsonLine()).length;

List<int> _times(LogBatch batch) =>
    [for (final line in batch.lines) (jsonDecode(line) as Map)['t'] as int];

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('file_log_store_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<FileLogStore> open({
    String sessionId = 'sess0001',
    int maxFileBytes = 1 << 20,
    int maxFiles = 5,
    void Function(String reason)? onDisabled,
  }) =>
      FileLogStore.open(
        dir,
        sessionId: sessionId,
        maxFileBytes: maxFileBytes,
        maxFiles: maxFiles,
        flushInterval: null,
        onDisabled: onDisabled,
      );

  int logFileCount() => dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ndjson'))
      .length;

  List<File> ndjsonFiles() => dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.ndjson'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('reads back what it wrote, oldest first', () async {
    final store = await open();
    for (var t = 1; t <= 3; t++) {
      store.add(_record(t));
    }

    final batch = await store.read(maxBytes: 1 << 20);

    expect(_times(batch), [1, 2, 3]);
    expect(batch.gap, isFalse);
  });

  test('a read from the returned cursor sees only newer lines', () async {
    final store = await open();
    store.add(_record(1));
    final first = await store.read(maxBytes: 1 << 20);
    store.add(_record(2));

    final second = await store.read(from: first.next, maxBytes: 1 << 20);

    expect(_times(second), [2]);
  });

  test('stops at maxBytes on a line boundary', () async {
    final store = await open();
    for (var t = 1; t <= 9; t++) {
      store.add(_record(t));
    }

    final batch = await store.read(maxBytes: _lineBytes() * 3 + 5);
    expect(_times(batch), [1, 2, 3]);

    final rest = await store.read(from: batch.next, maxBytes: 1 << 20);
    expect(_times(rest), [4, 5, 6, 7, 8, 9]);
  });

  test('stops before the first record after untilMs', () async {
    final store = await open();
    for (var t = 1; t <= 5; t++) {
      store.add(_record(t));
    }

    final batch = await store.read(maxBytes: 1 << 20, untilMs: 3);
    expect(_times(batch), [1, 2, 3]);

    final again =
        await store.read(from: batch.next, maxBytes: 1 << 20, untilMs: 3);
    expect(again.lines, isEmpty);
  });

  test('rotates at maxFileBytes and reads across files', () async {
    final store = await open(maxFileBytes: _lineBytes() * 2);
    for (var t = 1; t <= 5; t++) {
      store.add(_record(t));
      await store.flush();
    }

    expect(logFileCount(), greaterThan(1));
    expect(_times(await store.read(maxBytes: 1 << 20)), [1, 2, 3, 4, 5]);
  });

  test('keeps at most maxFiles files, dropping the oldest', () async {
    final store = await open(maxFileBytes: _lineBytes(), maxFiles: 3);
    for (var t = 1; t <= 6; t++) {
      store.add(_record(t));
      await store.flush();
    }

    expect(logFileCount(), lessThanOrEqualTo(3));
    expect(_times(await store.read(maxBytes: 1 << 20)), [5, 6]);
  });

  test(
      'a cursor into a rotated-away file resumes at the next one and flags a gap',
      () async {
    final store = await open(maxFileBytes: _lineBytes(), maxFiles: 3);
    store.add(_record(1));
    await store.flush();
    final early = await store.read(maxBytes: 1 << 20);
    for (var t = 2; t <= 6; t++) {
      store.add(_record(t));
      await store.flush();
    }

    final later = await store.read(from: early.next, maxBytes: 1 << 20);

    expect(later.gap, isTrue);
    expect(_times(later), [5, 6]);
  });

  test(
      'a trailing partial line in the newest file is held for the next '
      'write', () async {
    final store = await open();
    store.add(_record(1));
    await store.flush();
    final active = ndjsonFiles().single;
    // Simulates a write that has not reached its terminating newline yet.
    // Appended directly, bypassing the buffered writer, since the store
    // itself always writes whole lines.
    await active.writeAsString(jsonEncode(_record(2).toJson()),
        mode: FileMode.append);

    final batch = await store.read(maxBytes: 1 << 20);

    expect(_times(batch), [1]);
    expect(batch.gap, isFalse);
    expect(batch.next.file, active.uri.pathSegments.last);
    expect(batch.next.offset, utf8.encode(_record(1).toNdjsonLine()).length);
  });

  test(
      'a trailing partial line in an older, already-rotated file is '
      'skipped so later files are still read', () async {
    final store = await open();
    // An older, already-rotated file whose last line was never finished --
    // the process was killed mid-write. Nothing will ever append to it
    // again, so its dangling tail must not be held onto forever.
    final older = File(
        '${dir.path}${Platform.pathSeparator}0000000000001-sess0001-0000.ndjson');
    await older.writeAsString(
      '${_record(1).toNdjsonLine()}${jsonEncode(_record(2).toJson())}',
    );
    store.add(_record(3));
    await store.flush();

    final batch = await store.read(maxBytes: 1 << 20);

    expect(_times(batch), [1, 3]);
    expect(batch.gap, isFalse,
        reason: 'a partial trailing line is not the same loss as a whole '
            'rotated-away file, so it is not reported as a gap');
    final newer = ndjsonFiles().last;
    expect(batch.next.file, newer.uri.pathSegments.last);
    expect(batch.next.offset, utf8.encode(_record(3).toNdjsonLine()).length);
  });

  test('endCursor skips everything already written', () async {
    final store = await open();
    store.add(_record(1));
    final end = await store.endCursor();
    store.add(_record(2));

    expect(_times(await store.read(from: end, maxBytes: 1 << 20)), [2]);
  });

  test('endCursor on an empty store reads the next line without a gap',
      () async {
    final store = await open();
    final end = await store.endCursor();
    store.add(_record(1));

    final batch = await store.read(from: end, maxBytes: 1 << 20);

    expect(_times(batch), [1]);
    expect(batch.gap, isFalse);
  });

  test('persists the cursor across instances', () async {
    final store = await open();
    store.add(_record(1));
    final batch = await store.read(maxBytes: 1 << 20);
    await store.saveCursor(batch.next);

    final reopened = await open(sessionId: 'sess0002');

    expect(await reopened.loadCursor(), batch.next);
  });

  test('reports the size of every flush', () async {
    final store = await open();
    final sizes = <int>[];
    store.onFlushed = sizes.add;

    store.add(_record(1));
    await store.flush();

    expect(sizes, [_lineBytes()]);
  });

  test('stops writing after repeated failures and says why once', () async {
    final reasons = <String>[];
    final store = await open(onDisabled: reasons.add);
    await dir.delete(recursive: true);

    for (var i = 0; i < FileLogStore.failureLimit + 2; i++) {
      store.add(_record(i));
      await store.flush();
    }

    expect(reasons, hasLength(1));
  });

  test(
      'a file that becomes unreadable mid-read ends the read gracefully, '
      'keeping a resumable cursor', () async {
    final store = await open(maxFileBytes: _lineBytes(), maxFiles: 10);
    for (var t = 1; t <= 3; t++) {
      store.add(_record(t));
      await store.flush();
    }
    final files = ndjsonFiles();
    expect(files, hasLength(3));
    // Simulates a file that the periodic flush timer prunes between the
    // directory listing and the per-file read: the entry stays visible to
    // `_files()` (it is not removed), but can no longer be opened. A plain
    // delete would instead vanish from that listing entirely, so it would
    // never reach the guarded per-file read at all.
    final chmod = Process.runSync('chmod', ['000', files[1].path]);
    expect(chmod.exitCode, 0);
    addTearDown(() => Process.runSync('chmod', ['600', files[1].path]));

    final batch = await store.read(maxBytes: 1 << 20);

    expect(_times(batch), [1]);
    expect(batch.gap, isFalse);
    expect(batch.next.file, files[1].uri.pathSegments.last);
    expect(batch.next.offset, 0);
  });

  test('a foreign session file is spared until it goes stale', () async {
    final store = await open(maxFileBytes: _lineBytes(), maxFiles: 3);
    final foreign = File(
        '${dir.path}${Platform.pathSeparator}0000000000001-foreign1-0000.ndjson');
    foreign.writeAsStringSync('foreign\n');

    for (var t = 1; t <= 4; t++) {
      store.add(_record(t));
      await store.flush();
    }

    expect(foreign.existsSync(), isTrue);

    foreign
        .setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 2)));
    store.add(_record(5));
    await store.flush();

    expect(foreign.existsSync(), isFalse);
  });
}
