import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/logging/log_record.dart';
import 'package:player/core/logging/log_store.dart';
import 'package:player/core/logging/log_uploader.dart';

import '../../test_utils/memory_log_store.dart';

const _meta = LogUploadMeta(
  deviceId: 'd-1',
  deviceName: 'Work MacBook',
  platform: 'macos',
  osVersion: 'macOS 15.6',
  appVersion: '0.15.0',
  build: '150',
);

typedef _Request = ({
  Map<String, Object?> meta,
  List<Map<String, Object?>> lines
});

class _Harness {
  _Harness(
    this.async, {
    List<int> statuses = const [204],
    Map<String, String> headers = const {},
    int maxBatchBytes = 2 * 1024 * 1024,
  }) {
    var call = 0;
    uploader = LogUploader(
      client: MockClient((request) async {
        final text = utf8.decode(gzip.decode(request.bodyBytes));
        final lines = const LineSplitter().convert(text);
        requests.add((
          meta: jsonDecode(lines.first) as Map<String, Object?>,
          lines: [
            for (final line in lines.skip(1))
              jsonDecode(line) as Map<String, Object?>,
          ],
        ));
        final status =
            statuses[call < statuses.length ? call : statuses.length - 1];
        call++;
        return http.Response(
          status == 201 ? '{"code":"LOG-7K2QX9"}' : '',
          status,
          headers: headers,
        );
      }),
      endpoint: Uri.parse('https://relay.test/player-logs'),
      store: store,
      sessionId: 'sess0001',
      loadMeta: () async => _meta,
      compress: gzip.encode,
      now: () => start.add(async.elapsed),
      maxBatchBytes: maxBatchBytes,
    );
  }

  static final start = DateTime.utc(2026, 9, 22, 12);

  final FakeAsync async;
  final store = MemoryLogStore();
  late final LogUploader uploader;
  final requests = <_Request>[];

  void write(int count, {DateTime? at, String message = 'line'}) {
    for (var i = 0; i < count; i++) {
      store.add(LogRecord(
        time: at ?? start.add(async.elapsed),
        level: LogLevel.info,
        tag: 'Test',
        message: '$message ${store.records.length}',
        sessionId: 'sess0001',
      ));
    }
  }

  List<Object?> messages(int request) =>
      [for (final line in requests[request].lines) line['msg']];
}

void main() {
  group('continuous', () {
    test('uploads new records every minute and advances the cursor', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(3);

        async.elapse(const Duration(seconds: 61));

        expect(h.requests, hasLength(1));
        expect(h.requests.single.meta['kind'], 'stream');
        expect(h.requests.single.meta['device_id'], 'd-1');
        expect(h.messages(0), ['line 0', 'line 1', 'line 2']);
        expect(h.store.savedCursor, const LogCursor('mem', 3));

        async.elapse(const Duration(seconds: 60));
        expect(h.requests, hasLength(1), reason: 'nothing new, nothing sent');
      });
    });

    test('turning sharing on skips what was already written', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.write(2);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1);

        async.elapse(const Duration(seconds: 61));

        expect(h.messages(0), ['line 2']);
      });
    });

    test('a later launch keeps the persisted cursor', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.write(3);
        h.store.savedCursor = const LogCursor('mem', 1);
        h.uploader.activate(until: null, resetCursor: false);

        async.elapse(const Duration(seconds: 61));

        expect(h.messages(0), ['line 1', 'line 2']);
      });
    });

    test('sends early once enough is waiting', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();

        h.write(40, message: 'x' * 8000);
        async.flushMicrotasks();

        expect(h.requests, hasLength(1));
      });
    });

    test('never sends records after logs_until', () {
      fakeAsync((async) {
        final h = _Harness(async);
        final until = _Harness.start.add(const Duration(seconds: 30));
        h.uploader.activate(until: until, resetCursor: true);
        async.flushMicrotasks();
        h.write(1, at: _Harness.start.add(const Duration(seconds: 10)));
        h.write(1, at: _Harness.start.add(const Duration(seconds: 40)));

        async.elapse(const Duration(seconds: 61));

        expect(h.messages(0), ['line 0']);
      });
    });

    test('a failed batch is retried, then the cursor advances', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [503, 204]);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1);

        async.elapse(const Duration(seconds: 61));
        expect(h.requests, hasLength(1));
        expect(h.store.savedCursor, const LogCursor('mem', 0));

        async.elapse(const Duration(seconds: 60));
        expect(h.requests, hasLength(2));
        expect(h.store.savedCursor, const LogCursor('mem', 1));
      });
    });

    test('backoff doubles up to its cap', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [503]);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1);

        async.elapse(const Duration(seconds: 61));
        expect(h.uploader.backoff, LogUploader.minBackoff);

        async.elapse(const Duration(hours: 12));
        expect(h.uploader.backoff, LogUploader.maxBackoff);
      });
    });

    test('429 waits for Retry-After', () {
      fakeAsync((async) {
        final h = _Harness(async,
            statuses: [429, 204], headers: {'retry-after': '300'});
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1);

        async.elapse(const Duration(seconds: 61));
        async.elapse(const Duration(seconds: 180));
        expect(h.requests, hasLength(1));

        async.elapse(const Duration(seconds: 180));
        expect(h.requests, hasLength(2));
      });
    });

    test('413 splits the batch in half', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [413, 204]);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(4);

        async.elapse(const Duration(seconds: 61));

        expect(h.requests.map((r) => r.lines.length), [4, 2, 2]);
        expect(h.store.savedCursor, const LogCursor('mem', 4));
      });
    });

    test('400 drops the batch and moves on', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [400, 204]);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(2);

        async.elapse(const Duration(seconds: 61));
        expect(h.store.savedCursor, const LogCursor('mem', 2));

        h.write(1);
        async.elapse(const Duration(seconds: 60));
        expect(h.messages(1), ['line 2']);
      });
    });

    test('404 waits an hour', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [404, 204]);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1);

        async.elapse(const Duration(seconds: 61));
        async.elapse(const Duration(minutes: 59));
        expect(h.requests, hasLength(1));

        async.elapse(const Duration(minutes: 2));
        expect(h.requests, hasLength(2));
      });
    });

    test('a gap is announced at the start of the next batch', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.write(3);
        h.store.droppedBefore = 2;
        h.store.savedCursor = const LogCursor('mem', 1);
        h.uploader.activate(until: null, resetCursor: false);

        async.elapse(const Duration(seconds: 61));

        final lines = h.requests.single.lines;
        expect(lines.first['tag'], 'LogUploader');
        expect(lines.first['l'], 'warn');
        expect(lines.first['msg'], contains('gap'));
        expect(lines.last['msg'], 'line 2');
      });
    });

    test('deactivate with a final attempt sends what is left, then stops', () {
      fakeAsync((async) {
        final h = _Harness(async);
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(2);

        h.uploader.deactivate(finalAttempt: true);
        async.flushMicrotasks();

        expect(h.requests, hasLength(1));
        expect(h.uploader.isActive, isFalse);

        h.write(1);
        async.elapse(const Duration(minutes: 5));
        expect(h.requests, hasLength(1));
      });
    });
  });

  group('sendReport', () {
    test('sends every record under one code and returns it', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [201], maxBatchBytes: 400);
        h.write(6);

        String? code;
        h.uploader
            .sendReport(note: 'Stutters after seeking')
            .then((c) => code = c);
        async.flushMicrotasks();

        expect(code, 'LOG-7K2QX9');
        expect(h.requests.length, greaterThan(1));
        expect(h.requests.first.meta['kind'], 'report');
        expect(h.requests.first.meta['report'], isNull);
        expect(h.requests.first.meta['note'], 'Stutters after seeking');
        for (final later in h.requests.skip(1)) {
          expect(later.meta['report'], 'LOG-7K2QX9');
          expect(later.meta['note'], isNull);
        }
        expect(h.requests.expand((r) => r.lines).length, 6);
      });
    });

    test('ignores the stream cursor and starts at the oldest record', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [201]);
        h.write(3);
        h.store.savedCursor = const LogCursor('mem', 2);

        h.uploader.sendReport();
        async.flushMicrotasks();

        expect(h.requests.single.lines, hasLength(3));
      });
    });

    test('throws when there is nothing to send', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [201]);

        Object? error;
        h.uploader.sendReport().catchError((Object e) {
          error = e;
          return '';
        });
        async.flushMicrotasks();

        expect(error, isA<LogUploadException>());
      });
    });

    test('throws when the relay refuses', () {
      fakeAsync((async) {
        final h = _Harness(async, statuses: [400]);
        h.write(1);

        Object? error;
        h.uploader.sendReport().catchError((Object e) {
          error = e;
          return '';
        });
        async.flushMicrotasks();

        expect(error, isA<LogUploadException>());
      });
    });
  });
}
