/// The native half of player logging: rolling NDJSON files, and gzip.
///
/// Imported only through `log_platform.dart`, so web builds never see
/// `dart:io`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

import 'log_record.dart';
import 'log_store.dart';

/// Opens the store in `<app support>/logs`.
Future<LogStore?> openLogStore({
  required String sessionId,
  void Function(String reason)? onDisabled,
}) async {
  final support = await getApplicationSupportDirectory();
  return FileLogStore.open(
    Directory('${support.path}${Platform.pathSeparator}logs'),
    sessionId: sessionId,
    onDisabled: onDisabled,
  );
}

List<int> gzipBytes(List<int> input) => gzip.encode(input);

/// Rolling NDJSON files with one active file at a time.
///
/// Files are named `<epoch ms, 13 digits>-<session>-<seq, 4 digits>.ndjson`,
/// so sorting by name sorts by time, and a second instance of the app, which
/// has its own session ID, never writes into the first one's file. The active
/// file rotates at [maxFileBytes]; at most [maxFiles] are kept.
class FileLogStore implements LogStore {
  FileLogStore._(
    this._dir,
    this._sessionId,
    this._now,
    this._maxFileBytes,
    this._maxFiles,
    this._onDisabled,
  );

  static Future<FileLogStore> open(
    Directory dir, {
    required String sessionId,
    DateTime Function()? now,
    int maxFileBytes = 2 * 1024 * 1024,
    int maxFiles = 5,
    Duration? flushInterval = const Duration(seconds: 1),
    void Function(String reason)? onDisabled,
  }) async {
    await dir.create(recursive: true);
    final store = FileLogStore._(
      dir,
      sessionId,
      now ?? DateTime.now,
      maxFileBytes,
      maxFiles,
      onDisabled,
    );
    store._active = store._nextFile();
    await store._prune();
    if (flushInterval != null) {
      store._timer =
          Timer.periodic(flushInterval, (_) => unawaited(store.flush()));
    }
    return store;
  }

  /// Consecutive failed writes after which the store stops trying.
  static const failureLimit = 5;
  static const _flushAtRecords = 100;
  static const _newline = 0x0A;

  /// How old a file written by another session must be before this store
  /// will prune it. A second instance of the app shares this directory and
  /// is named in the file list the same way, so pruning by raw file count
  /// without this grace period lets one instance delete the active file a
  /// live sibling is still appending to. Stale foreign files still get
  /// collected past the grace period so the directory stays bounded once
  /// that sibling is gone.
  static const _foreignFileGrace = Duration(hours: 1);

  final Directory _dir;
  final String _sessionId;
  final DateTime Function() _now;
  final int _maxFileBytes;
  final int _maxFiles;
  final void Function(String reason)? _onDisabled;

  late File _active;
  int _activeBytes = 0;
  int _seq = 0;
  final StringBuffer _buffer = StringBuffer();
  int _buffered = 0;
  Future<void> _writing = Future<void>.value();
  int _failures = 0;
  bool _disabled = false;
  Timer? _timer;
  void Function(int bytes)? _onFlushed;

  @override
  set onFlushed(void Function(int bytes)? callback) => _onFlushed = callback;

  @override
  void add(LogRecord record) {
    if (_disabled) return;
    _buffer.write(record.toNdjsonLine());
    if (++_buffered >= _flushAtRecords) unawaited(flush());
  }

  @override
  Future<void> flush() => _writing = _writing.then((_) => _flushBuffer());

  // Never throws: a failed flush would otherwise poison [_writing] and every
  // flush chained after it.
  Future<void> _flushBuffer() async {
    if (_disabled || _buffered == 0) return;
    final bytes = utf8.encode(_buffer.toString());
    // Cleared before the write is attempted, and dropped rather than
    // requeued on failure: holding a failed batch in memory while the disk
    // keeps failing risks unbounded growth, which is worse for a
    // diagnostics feature than losing a few lines. failureLimit disables
    // the store once losses repeat.
    _buffer.clear();
    _buffered = 0;
    try {
      await _active.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    } catch (e) {
      if (++_failures >= failureLimit) {
        _disabled = true;
        _timer?.cancel();
        _onDisabled?.call('$e');
      }
      return;
    }
    _failures = 0;
    _activeBytes += bytes.length;
    _onFlushed?.call(bytes.length);
    if (_activeBytes >= _maxFileBytes) {
      _active = _nextFile();
      await _prune();
    }
  }

  File _nextFile() {
    final stamp =
        _now().toUtc().millisecondsSinceEpoch.toString().padLeft(13, '0');
    final seq = (_seq++).toString().padLeft(4, '0');
    _activeBytes = 0;
    return File(
        '${_dir.path}${Platform.pathSeparator}$stamp-$_sessionId-$seq.ndjson');
  }

  static String _nameOf(File file) => file.uri.pathSegments.last;

  /// True when [file]'s name carries this store's own session ID, per the
  /// `<stamp>-<session>-<seq>.ndjson` naming scheme.
  bool _isOwnFile(File file) => _nameOf(file).contains('-$_sessionId-');

  Future<List<File>> _files() async {
    final files = <File>[];
    await for (final entity in _dir.list()) {
      if (entity is File && entity.path.endsWith('.ndjson')) files.add(entity);
    }
    files.sort((a, b) => _nameOf(a).compareTo(_nameOf(b)));
    return files;
  }

  Future<void> _prune() async {
    try {
      final others =
          (await _files()).where((f) => f.path != _active.path).toList();
      final own = others.where(_isOwnFile).toList();
      final foreignCutoff = _now().toUtc().subtract(_foreignFileGrace);
      final staleForeign = <File>[];
      for (final file in others) {
        if (_isOwnFile(file)) continue;
        if ((await file.lastModified()).toUtc().isBefore(foreignCutoff)) {
          staleForeign.add(file);
        }
      }
      // The active file counts against maxFiles too.
      while (own.length > _maxFiles - 1) {
        await _tryDelete(own.removeAt(0));
      }
      for (final file in staleForeign) {
        await _tryDelete(file);
      }
    } on FileSystemException {
      // The directory itself is unreadable; the next write says so.
    }
  }

  Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  File get _cursorFile =>
      File('${_dir.path}${Platform.pathSeparator}cursor.json');

  @override
  Future<LogCursor?> loadCursor() async {
    try {
      return LogCursor.fromJson(jsonDecode(await _cursorFile.readAsString()));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveCursor(LogCursor cursor) async {
    final tmp = File('${_cursorFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(cursor.toJson()), flush: true);
    await tmp.rename(_cursorFile.path);
  }

  @override
  Future<LogCursor> endCursor() async {
    await flush();
    // Created when missing, so a cursor saved now always names a real file
    // and a later read cannot mistake it for one that was rotated away.
    if (!await _active.exists()) await _active.create(recursive: true);
    return LogCursor(_nameOf(_active), await _active.length());
  }

  @override
  Future<LogBatch> read({
    LogCursor? from,
    required int maxBytes,
    int? untilMs,
  }) async {
    await flush();
    final List<File> files;
    try {
      files = await _files();
    } on FileSystemException {
      return LogBatch(
          lines: const [],
          next: from ?? LogCursor(_nameOf(_active), 0),
          gap: false);
    }
    if (files.isEmpty) {
      return LogBatch(
          lines: const [],
          next: from ?? LogCursor(_nameOf(_active), 0),
          gap: false);
    }

    var index = 0;
    var offset = 0;
    var gap = false;
    if (from != null) {
      index = files.indexWhere((f) => _nameOf(f) == from.file);
      offset = from.offset;
      if (index < 0) {
        index = files.indexWhere((f) => _nameOf(f).compareTo(from.file) > 0);
        offset = 0;
        if (index < 0) return LogBatch(lines: const [], next: from, gap: false);
        gap = true;
      }
    }

    final lines = <String>[];
    var budget = maxBytes;
    var cursor = LogCursor(_nameOf(files[index]), offset);

    reading:
    while (budget > 0) {
      final file = files[index];
      final int length;
      List<int>? chunk;
      try {
        length = await file.length();
        if (offset < length) {
          chunk =
              await _readRange(file, offset, math.min(budget, length - offset));
        }
      } on FileSystemException {
        // The file was rotated away or became unreadable between the
        // directory listing above and here (the periodic flush timer can
        // prune a file mid-read). Stop and hand back what was gathered so
        // far; [cursor] still names this file at its last known offset, so
        // the next read rediscovers it is gone and reports the gap itself.
        break reading;
      }
      if (chunk != null) {
        var start = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != _newline) continue;
          final line =
              utf8.decode(chunk.sublist(start, i), allowMalformed: true);
          if (untilMs != null && _timeOf(line) > untilMs) {
            offset += start;
            cursor = LogCursor(_nameOf(file), offset);
            break reading;
          }
          if (line.isNotEmpty) lines.add(line);
          start = i + 1;
        }
        offset += start;
        budget -= start;
        cursor = LogCursor(_nameOf(file), offset);
        // Out of budget mid-file, or a last line still waiting for its newline.
        if (offset < length) break;
      }
      if (index == files.length - 1) break;
      index++;
      offset = 0;
      cursor = LogCursor(_nameOf(files[index]), 0);
    }

    return LogBatch(lines: lines, next: cursor, gap: gap);
  }

  static Future<List<int>> _readRange(File file, int offset, int length) async {
    final raf = await file.open();
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  static int _timeOf(String line) {
    try {
      final t = (jsonDecode(line) as Map)['t'];
      return t is int ? t : 0;
    } catch (_) {
      return 0;
    }
  }
}
