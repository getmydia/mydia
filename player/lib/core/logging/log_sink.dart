/// Captures everything the player logs, for the local log files and, when the
/// user shares them, the relay.
///
/// [LogSink.install] wraps the global `debugPrint`, so the player's existing
/// `debugPrint('[Tag] ...')` calls are captured without touching one of them,
/// and console output is unchanged. Rust `tracing` events arrive through
/// [LogSink.recordRustEvent] from `P2pService`'s event stream.
///
/// Every record is redacted (`log_redactor.dart`) and truncated before it is
/// stored. Records made before [attach] wait in memory, up to [maxPending].
/// Nothing here throws or awaits on the caller's path, and the sink reports
/// its own trouble on the original `debugPrint`, never through itself.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'log_record.dart';
import 'log_redactor.dart';
import 'log_store.dart';

/// The prefix `event_stream` puts on a forwarded Rust log line.
const rustLogEventPrefix = 'log:';

class LogSink {
  LogSink({
    required this.sessionId,
    DateTime Function()? now,
    DebugPrintCallback? console,
  })  : _now = now ?? DateTime.now,
        _console = console ?? debugPrint;

  static LogSink? _instance;

  /// The sink `main()` installed, or null (web, tests).
  static LogSink? get instance => _instance;

  static const maxPending = 5000;
  static const _stackFrames = 20;

  /// How much of a message [_add] hands to [redactLogMessage] before the
  /// final [LogRecord.truncate].
  ///
  /// Twice [LogRecord.maxMessageChars], not exactly [LogRecord.maxMessageChars]:
  /// redaction can lengthen a message (a short secret becomes `[REDACTED]`),
  /// and cutting at exactly the limit can slice a secret in half, leaving an
  /// unmatched fragment of it in plain text right at the truncation boundary
  /// where [LogRecord.truncate] would otherwise have removed the whole thing.
  /// Cutting at twice the limit instead guarantees that any secret whose
  /// start survives into the final, truncated output also has its entire
  /// span included in this pre-cut, so [redactLogMessage] sees it whole and
  /// redacts it whole; a secret fragment beyond that is discarded by
  /// [LogRecord.truncate] a moment later and can never reach the stored
  /// record either way.
  static const _preRedactChars = LogRecord.maxMessageChars * 2;

  final String sessionId;
  final DateTime Function() _now;
  final DebugPrintCallback _console;
  final List<LogRecord> _pending = [];
  LogStore? _store;

  /// Wraps `debugPrint` and makes the new sink [instance].
  static LogSink install({DateTime Function()? now}) {
    final original = debugPrint;
    final sink =
        LogSink(sessionId: newSessionId(), now: now, console: original);
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) sink.recordLine(message);
      original(message, wrapWidth: wrapWidth);
    };
    _instance = sink;
    return sink;
  }

  @visibleForTesting
  static void resetForTesting() => _instance = null;

  /// Eight random hex characters, one per app launch.
  static String newSessionId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 4; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Sends every record to [store] from now on, starting with those waiting.
  void attach(LogStore store) {
    _store = store;
    final waiting = List<LogRecord>.of(_pending);
    _pending.clear();
    for (final record in waiting) {
      _safely(() => store.add(record));
    }
  }

  void recordLine(String line, {LogLevel level = LogLevel.info}) => _safely(() {
        final (tag, message) = splitTag(line);
        _add(tag: tag, message: message, level: level);
      });

  void recordError(Object error, StackTrace? stack) => _safely(() {
        final frames = stack
            ?.toString()
            .split('\n')
            .where((line) => line.isNotEmpty)
            .take(_stackFrames)
            .join('\n');
        _add(
          tag: 'Error',
          message:
              frames == null || frames.isEmpty ? '$error' : '$error\n$frames',
          level: LogLevel.error,
        );
      });

  /// Records a Rust `tracing` event forwarded as `{"l","target","msg"}`.
  void recordRustEvent(String json) => _safely(() {
        final decoded = jsonDecode(json);
        if (decoded is! Map) return;
        final target = decoded['target'];
        final message = decoded['msg'];
        _add(
          tag: target is String && target.isNotEmpty ? target : 'rust',
          message: message is String ? message : '$message',
          level: LogLevel.fromWire(decoded['l']) ?? LogLevel.info,
          source: LogSource.rust,
        );
      });

  /// One `Session` record describing this launch.
  void recordSession(Map<String, String> fields) => _safely(() => _add(
        tag: 'Session',
        message: fields.entries.map((e) => '${e.key}="${e.value}"').join(' '),
        level: LogLevel.info,
      ));

  /// Prints without recording, for the sink's and the store's own trouble.
  void consoleOnly(String message) => _console(message);

  void _add({
    required String tag,
    required String message,
    required LogLevel level,
    LogSource source = LogSource.dart,
  }) {
    final preCut = message.length > _preRedactChars
        ? message.substring(0, _preRedactChars)
        : message;
    final record = LogRecord(
      time: _now().toUtc(),
      level: level,
      tag: tag,
      message: LogRecord.truncate(redactLogMessage(preCut)),
      sessionId: sessionId,
      source: source,
    );
    final store = _store;
    if (store != null) {
      store.add(record);
    } else if (_pending.length < maxPending) {
      _pending.add(record);
    }
  }

  void _safely(void Function() work) {
    try {
      work();
    } catch (e) {
      try {
        _console('[LogSink] Dropped a record: $e');
      } catch (_) {}
    }
  }
}
