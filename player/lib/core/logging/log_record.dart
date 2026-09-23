/// One line of the player's log, as it is stored on disk and uploaded.
///
/// Serialized as one JSON object per line (NDJSON). The relay's
/// `MetadataRelay.PlayerLogs.Ingest` validates exactly these keys, so a
/// change here is a wire change.
library;

import 'dart:convert';

enum LogLevel {
  debug,
  info,
  warn,
  error;

  /// The level named [value], or null for anything else.
  static LogLevel? fromWire(Object? value) {
    for (final level in values) {
      if (level.name == value) return level;
    }
    return null;
  }
}

enum LogSource { dart, rust }

class LogRecord {
  const LogRecord({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
    required this.sessionId,
    this.source = LogSource.dart,
  });

  /// Longest message kept, matching the relay's own cap.
  static const maxMessageChars = 8192;
  static const truncationMarker = '...[truncated]';

  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;
  final String sessionId;
  final LogSource source;

  Map<String, Object?> toJson() => {
        't': time.millisecondsSinceEpoch,
        'l': level.name,
        'tag': tag,
        'msg': message,
        'sid': sessionId,
        'src': source.name,
      };

  String toNdjsonLine() => '${jsonEncode(toJson())}\n';

  /// [message] cut to [maxMessageChars], marked when cut.
  static String truncate(String message) => message.length <= maxMessageChars
      ? message
      : '${message.substring(0, maxMessageChars)}$truncationMarker';
}

final _tagPattern = RegExp(r'^\[([^\[\]\s]{1,64})\] ?');

/// Splits the `[Tag] ` prefix nearly every `debugPrint` in the player
/// carries. A line without one gets the tag `app`.
(String, String) splitTag(String line) {
  final match = _tagPattern.firstMatch(line);
  if (match == null) return ('app', line);
  return (match[1]!, line.substring(match.end));
}
