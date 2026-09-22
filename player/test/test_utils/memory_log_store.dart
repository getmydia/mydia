import 'dart:convert';

import 'package:player/core/logging/log_record.dart';
import 'package:player/core/logging/log_store.dart';

/// An in-memory [LogStore]. The cursor's offset is an index into [records],
/// and every cursor names the file `mem`.
class MemoryLogStore implements LogStore {
  final List<LogRecord> records = [];
  LogCursor? savedCursor;

  /// When true, [add] throws, as a full disk would.
  bool failAdds = false;

  /// Records before this index count as rotated away.
  int droppedBefore = 0;

  int flushes = 0;

  void Function(int bytes)? _onFlushed;

  @override
  set onFlushed(void Function(int bytes)? callback) => _onFlushed = callback;

  @override
  void add(LogRecord record) {
    if (failAdds) throw StateError('disk full');
    records.add(record);
    _onFlushed?.call(utf8.encode(record.toNdjsonLine()).length);
  }

  @override
  Future<void> flush() async => flushes++;

  @override
  Future<LogCursor?> loadCursor() async => savedCursor;

  @override
  Future<void> saveCursor(LogCursor cursor) async => savedCursor = cursor;

  @override
  Future<LogCursor> endCursor() async => LogCursor('mem', records.length);

  @override
  Future<LogBatch> read({
    LogCursor? from,
    required int maxBytes,
    int? untilMs,
  }) async {
    var index = from?.offset ?? droppedBefore;
    final gap = from != null && index < droppedBefore;
    if (index < droppedBefore) index = droppedBefore;

    final lines = <String>[];
    var used = 0;
    while (index < records.length) {
      final record = records[index];
      if (untilMs != null && record.time.millisecondsSinceEpoch > untilMs) {
        break;
      }
      final line = jsonEncode(record.toJson());
      if (lines.isNotEmpty && used + line.length + 1 > maxBytes) break;
      lines.add(line);
      used += line.length + 1;
      index++;
    }
    return LogBatch(lines: lines, next: LogCursor('mem', index), gap: gap);
  }
}
