import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/logging/log_record.dart';
import 'package:player/core/logging/log_sink.dart';

import '../../test_utils/memory_log_store.dart';

void main() {
  late DebugPrintCallback originalDebugPrint;
  final now = DateTime.utc(2026, 9, 22, 14, 3, 12, 345);

  setUp(() => originalDebugPrint = debugPrint);

  tearDown(() {
    debugPrint = originalDebugPrint;
    LogSink.resetForTesting();
  });

  test('install records debugPrint and still prints it', () {
    final printed = <String?>[];
    debugPrint = (String? message, {int? wrapWidth}) => printed.add(message);
    final sink = LogSink.install(now: () => now);
    final store = MemoryLogStore();
    sink.attach(store);

    debugPrint('[PlaybackController] Opened the stream');

    expect(printed, ['[PlaybackController] Opened the stream']);
    final record = store.records.single;
    expect(record.tag, 'PlaybackController');
    expect(record.message, 'Opened the stream');
    expect(record.level, LogLevel.info);
    expect(record.time, now);
    expect(record.sessionId, sink.sessionId);
    expect(LogSink.instance, same(sink));
  });

  test('records made before attach wait, then drain in order', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    sink.recordLine('[A] one');
    sink.recordLine('[B] two');
    final store = MemoryLogStore();

    sink.attach(store);

    expect(store.records.map((r) => r.tag), ['A', 'B']);
  });

  test('the pending buffer stops at maxPending', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    for (var i = 0; i < LogSink.maxPending + 10; i++) {
      sink.recordLine('line $i');
    }
    final store = MemoryLogStore();

    sink.attach(store);

    expect(store.records, hasLength(LogSink.maxPending));
  });

  test('redacts before storing', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    sink.recordLine('[Hls] GET /master.m3u8?token=abc123');

    expect(store.records.single.message, 'GET /master.m3u8?token=[REDACTED]');
  });

  test('recordError stores an error record with the stack', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    sink.recordError(StateError('boom'), StackTrace.fromString('#0 a\n#1 b\n'));

    final record = store.records.single;
    expect(record.level, LogLevel.error);
    expect(record.tag, 'Error');
    expect(record.message, 'Bad state: boom\n#0 a\n#1 b');
  });

  test('recordRustEvent keeps the level and target', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    sink.recordRustEvent(
        '{"l":"warn","target":"iroh::magicsock","msg":"path lost"}');

    final record = store.records.single;
    expect(record.source, LogSource.rust);
    expect(record.tag, 'iroh::magicsock');
    expect(record.level, LogLevel.warn);
    expect(record.message, 'path lost');
  });

  test('recordRustEvent ignores malformed input', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    sink.recordRustEvent('not json');
    sink.recordRustEvent('[1, 2]');

    expect(store.records, isEmpty);
  });

  test('recordSession writes one Session record', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    sink.recordSession({'version': '0.15.0', 'device': 'Work MacBook'});

    final record = store.records.single;
    expect(record.tag, 'Session');
    expect(record.message, 'version="0.15.0" device="Work MacBook"');
  });

  test('a throwing store never reaches the caller', () {
    final console = <String?>[];
    final sink = LogSink(
      sessionId: 's',
      now: () => now,
      console: (message, {wrapWidth}) => console.add(message),
    );
    sink.attach(MemoryLogStore()..failAdds = true);

    expect(() => sink.recordLine('x'), returnsNormally);
    expect(console.single, startsWith('[LogSink] Dropped a record'));
  });

  test(
      'a message far longer than the limit is stored truncated, and a '
      'secret placed beyond the pre-cut cannot appear', () {
    final sink =
        LogSink(sessionId: 's', now: () => now, console: (_, {wrapWidth}) {});
    final store = MemoryLogStore();
    sink.attach(store);

    // Filler alone already exceeds the pre-redaction cut
    // (LogRecord.maxMessageChars * 2), so the secret that follows it sits
    // entirely beyond that cut and is dropped before redactLogMessage ever
    // sees it.
    final filler = 'a' * (LogRecord.maxMessageChars * 2 + 1000);
    const secret = 'token=sk_live_should_never_appear';

    sink.recordLine('[Huge] $filler $secret');

    final record = store.records.single;
    expect(
      record.message.length,
      LogRecord.maxMessageChars + LogRecord.truncationMarker.length,
    );
    expect(record.message, endsWith(LogRecord.truncationMarker));
    expect(record.message, isNot(contains('sk_live_should_never_appear')));
  });

  test('new session IDs are 8 hex characters and differ', () {
    final a = LogSink.newSessionId();
    final b = LogSink.newSessionId();
    expect(a, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(a, isNot(b));
  });
}
