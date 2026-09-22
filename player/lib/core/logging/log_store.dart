/// Where the player keeps its log lines until they are uploaded.
///
/// Pure Dart, so web compiles it. The file-backed implementation is in
/// `log_platform_io.dart`, reached through `log_platform.dart`.
library;

import 'log_record.dart';

/// A position in the local log: a file and a byte offset into it.
class LogCursor {
  const LogCursor(this.file, this.offset);

  final String file;
  final int offset;

  Map<String, Object?> toJson() => {'file': file, 'offset': offset};

  static LogCursor? fromJson(Object? json) {
    if (json is Map && json['file'] is String && json['offset'] is int) {
      return LogCursor(json['file'] as String, json['offset'] as int);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LogCursor && other.file == file && other.offset == offset;

  @override
  int get hashCode => Object.hash(file, offset);

  @override
  String toString() => 'LogCursor($file, $offset)';
}

/// Complete NDJSON lines read from the store, and where reading stopped.
class LogBatch {
  const LogBatch({required this.lines, required this.next, required this.gap});

  /// Each line without its trailing newline.
  final List<String> lines;
  final LogCursor next;

  /// True when the file the cursor pointed into was rotated away first, so
  /// some lines were lost before anyone read them.
  final bool gap;

  bool get isEmpty => lines.isEmpty;
}

abstract class LogStore {
  /// Buffers [record]. Never awaits and never throws.
  void add(LogRecord record);

  /// Writes what [add] buffered. Never throws.
  Future<void> flush();

  /// Complete lines after [from], or from the oldest line when [from] is null,
  /// up to [maxBytes] of text. Stops before the first record whose `t` is after
  /// [untilMs]. Flushes first.
  Future<LogBatch> read({LogCursor? from, required int maxBytes, int? untilMs});

  /// The uploader's cursor, or null if none was saved.
  Future<LogCursor?> loadCursor();

  Future<void> saveCursor(LogCursor cursor);

  /// A cursor past everything written so far.
  Future<LogCursor> endCursor();

  /// Called with the byte count of every successful flush.
  set onFlushed(void Function(int bytes)? callback);
}
