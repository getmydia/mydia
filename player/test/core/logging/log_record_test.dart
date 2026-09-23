import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/logging/log_record.dart';

void main() {
  final record = LogRecord(
    time: DateTime.utc(2026, 9, 22, 14, 3, 12, 345),
    level: LogLevel.warn,
    tag: 'P2P',
    message: 'path lost',
    sessionId: 'a3f09c1e',
  );

  test('serializes the keys the relay validates', () {
    expect(record.toJson(), {
      't': 1790085792345,
      'l': 'warn',
      'tag': 'P2P',
      'msg': 'path lost',
      'sid': 'a3f09c1e',
      'src': 'dart',
    });
  });

  test('an NDJSON line is the JSON plus a newline', () {
    final line = record.toNdjsonLine();
    expect(line.endsWith('\n'), isTrue);
    expect(jsonDecode(line.trim()), record.toJson());
  });

  test('truncate cuts long messages and marks the cut', () {
    final long = 'x' * (LogRecord.maxMessageChars + 10);
    expect(LogRecord.truncate(long),
        '${'x' * LogRecord.maxMessageChars}${LogRecord.truncationMarker}');
    expect(LogRecord.truncate('short'), 'short');
  });

  test('fromWire reads level names and nothing else', () {
    expect(LogLevel.fromWire('error'), LogLevel.error);
    expect(LogLevel.fromWire('loud'), isNull);
    expect(LogLevel.fromWire(3), isNull);
  });

  group('splitTag', () {
    test('takes a leading [Tag]', () {
      expect(splitTag('[P2P] Event: ready'), ('P2P', 'Event: ready'));
      expect(splitTag('[RustLib]Initialized'), ('RustLib', 'Initialized'));
    });

    test('falls back to app', () {
      expect(splitTag('Caught error: boom'), ('app', 'Caught error: boom'));
      expect(splitTag('[not a tag] x'), ('app', '[not a tag] x'));
    });
  });
}
