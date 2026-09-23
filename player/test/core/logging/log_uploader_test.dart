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
    void Function(int callIndex)? onRequest,
    bool throwOnRequest = false,
  }) {
    var call = 0;
    uploader = LogUploader(
      client: MockClient((request) async {
        onRequest?.call(call);
        if (throwOnRequest) {
          throw const SocketException('network unreachable');
        }
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
        statusesSent.add(status);
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

  /// The status returned for each request, in the same order as [requests].
  final statusesSent = <int>[];

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

  /// Every message from a request the relay actually accepted (2xx), in
  /// the order the requests were sent. Used to check nothing the relay
  /// stored was ever sent again in a later request.
  List<Object?> deliveredMessages() => [
        for (var i = 0; i < requests.length; i++)
          if (statusesSent[i] >= 200 && statusesSent[i] < 300) ...messages(i),
      ];
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

    test(
        'turning sharing off mid-drain cannot leak a record past the '
        'original logs_until', () {
      fakeAsync((async) {
        late final _Harness h;
        h = _Harness(
          async,
          maxBatchBytes: 100,
          onRequest: (callIndex) {
            // Simulates the Diagnostics choice being turned off (or the
            // window expiring) while a multi-batch drain is still in
            // flight: deactivate() nulls _until as a side effect.
            if (callIndex == 0) h.uploader.deactivate();
          },
        );
        final until = _Harness.start.add(const Duration(seconds: 30));
        h.uploader.activate(until: until, resetCursor: true);
        async.flushMicrotasks();
        h.write(2, at: _Harness.start.add(const Duration(seconds: 10)));
        h.write(1, at: _Harness.start.add(const Duration(seconds: 40)));

        async.elapse(const Duration(seconds: 61));

        expect(h.uploader.isActive, isFalse);
        expect(h.requests, isNotEmpty);
        for (final request in h.requests) {
          for (final line in request.lines) {
            expect(
              line['t'],
              lessThanOrEqualTo(until.millisecondsSinceEpoch),
              reason: 'a line after logs_until must never be uploaded',
            );
          }
        }

        final requestsAtDeactivate = h.requests.length;
        async.elapse(const Duration(minutes: 10));
        expect(h.requests.length, requestsAtDeactivate,
            reason: 'a stale drain must not keep sending after deactivate()');
      });
    });

    test(
        'deactivate() mid-drain with no logs_until stops further requests '
        'and never sends a record written after it', () {
      fakeAsync((async) {
        late final _Harness h;
        h = _Harness(
          async,
          maxBatchBytes: 100,
          onRequest: (callIndex) {
            if (callIndex == 0) {
              h.uploader.deactivate();
              // Written the instant sharing turns off, while the drain
              // that started before that is still unwinding a multi-batch
              // backlog. The consent copy promises this is never sent.
              h.write(1, message: 'after-deactivate');
            }
          },
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(6);

        async.elapse(const Duration(seconds: 61));
        final requestsAtDeactivate = h.requests.length;

        // If the loop still failed to re-check `_active`, it would keep
        // draining the rest of the six-record backlog across these later
        // ticks.
        async.elapse(const Duration(minutes: 10));

        expect(h.uploader.isActive, isFalse);
        expect(h.requests.length, requestsAtDeactivate,
            reason: 'deactivate() mid-drain must stop further requests');
        final sent = [
          for (var i = 0; i < h.requests.length; i++) ...h.messages(i),
        ];
        expect(
          sent.any((m) => m.toString().startsWith('after-deactivate')),
          isFalse,
          reason: 'a record written after deactivate() must never be sent',
        );
      });
    });

    test(
        'reactivating with a reset cursor after a mid-drain deactivate is '
        'not overwritten by the stale drain, and skips what was written '
        'while sharing was off', () {
      fakeAsync((async) {
        late final _Harness h;
        h = _Harness(
          async,
          maxBatchBytes: 100,
          onRequest: (callIndex) {
            if (callIndex == 0) h.uploader.deactivate();
          },
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(6);

        async.elapse(const Duration(seconds: 61));
        expect(h.uploader.isActive, isFalse);

        // Written while sharing was off. The consent copy promises these
        // never reach the relay, even once sharing is turned back on with
        // a reset cursor meant to skip exactly this kind of backlog.
        h.write(2, message: 'while-off');

        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(1, message: 'after-reactivate');

        async.elapse(const Duration(seconds: 61));

        expect(h.uploader.isActive, isTrue);
        final sent = [
          for (var i = 0; i < h.requests.length; i++) ...h.messages(i),
        ];
        for (final message in sent) {
          expect(message.toString(), isNot(startsWith('while-off')),
              reason: 'nothing written while sharing was off may be sent');
        }
        expect(sent, contains('after-reactivate 8'));
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

    test('413 shrinks the batch and retries from the same cursor', () {
      fakeAsync((async) {
        // Big enough that all 4 lines fit in one read (triggering the
        // 413), and small enough that half that budget only fits 2.
        final h = _Harness(
          async,
          statuses: [413, 204],
          maxBatchBytes: 200340,
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(4, message: 'x' * 50000);
        final written = [for (var i = 0; i < 4; i++) '${'x' * 50000} $i'];

        async.elapse(const Duration(seconds: 61));

        expect(h.requests, hasLength(3));
        expect(h.messages(0), written, reason: 'the rejected attempt');
        expect(h.messages(1), written.sublist(0, 2));
        expect(h.messages(2), written.sublist(2, 4));
        expect(h.store.savedCursor, const LogCursor('mem', 4));

        // The 413 attempt was never accepted, so only what the 204s
        // actually carried should ever have landed on the relay, each
        // line exactly once.
        final delivered = h.deliveredMessages();
        expect(delivered.length, written.length);
        expect(delivered.toSet(), written.toSet());
      });
    });

    test('a 413 at the smallest batch is rejected, not shrunk forever', () {
      fakeAsync((async) {
        // A relay that answers 413 no matter what is sent. 20 short lines
        // total well under even the shrink floor, so every read at every
        // budget level returns all of them: the batch never becomes a
        // single line on its own, only the floor check can stop the loop.
        final h = _Harness(
          async,
          statuses: [413],
          maxBatchBytes: 1024 * 1024,
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(20);

        // If this elapse call returns at all, the drain finished instead
        // of spinning forever inside the timer callback.
        async.elapse(const Duration(seconds: 61));

        // 1 MiB halves to the 64 KiB floor in exactly 4 steps (1024K,
        // 512K, 256K, 128K, then 64K), so there are 4 _Shrink outcomes
        // followed by exactly one _Rejected outcome at the floor: 5
        // requests total, never more, however long the relay keeps
        // answering 413.
        expect(h.requests, hasLength(5));
        expect(h.store.savedCursor, const LogCursor('mem', 20));
      });
    });

    test(
        'a partial acceptance followed by a failure never resends what '
        'already landed', () {
      fakeAsync((async) {
        // 6 lines, each just over 20 KB. All 6 add up to well under
        // sizeTrigger (256 KiB), so writing them does not itself kick
        // off an early tick; a single shrink clamps straight to the 64
        // KiB floor (half of the total is already under it), and the
        // floor holds exactly 3 of the 6, so the first accepted request
        // covers only part of the batch. That is the shape that
        // duplicated lines under the old split-and-recurse code: accept
        // the first half, then fail the rest before the cursor moves
        // past it.
        final h = _Harness(
          async,
          statuses: [413, 204, 429, 204],
          maxBatchBytes: 120510,
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(6, message: 'x' * 20000);
        final written = [for (var i = 0; i < 6; i++) '${'x' * 20000} $i'];

        async.elapse(const Duration(seconds: 61));
        expect(h.requests, hasLength(3),
            reason: '413 shrinks, the shrunk batch is accepted, '
                'the remainder gets a 429');
        expect(h.messages(1), written.sublist(0, 3),
            reason: 'the shrunk batch the relay actually accepted');
        expect(h.store.savedCursor, const LogCursor('mem', 3),
            reason: 'the accepted half must be durable even though the '
                'request as a whole is still in progress');

        async.elapse(const Duration(seconds: 60));
        expect(h.requests, hasLength(4));
        expect(h.store.savedCursor, const LogCursor('mem', 6));

        // The proof: every line the relay ever returned a 2xx for, in
        // the order it was sent, with nothing repeated. Under the old
        // split-and-recurse code the first half (already accepted here)
        // would be resent whole alongside the second half once the
        // retry succeeds, so this fails against that code with 9
        // entries instead of 6, lines 0 through 2 doubled.
        expect(h.deliveredMessages(), written);
      });
    });

    test(
        'a failed retry after a 413 shrink never duplicates a line once a '
        'later attempt succeeds', () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          statuses: [413, 503, 204],
          maxBatchBytes: 200340,
        );
        h.uploader.activate(until: null, resetCursor: true);
        async.flushMicrotasks();
        h.write(4, message: 'x' * 50000);
        final written = [for (var i = 0; i < 4; i++) '${'x' * 50000} $i'];

        async.elapse(const Duration(seconds: 61));
        expect(h.requests, hasLength(2), reason: '413 then the 503 throws');
        expect(h.store.savedCursor, const LogCursor('mem', 0),
            reason: 'nothing was ever accepted, so the cursor must not move');

        async.elapse(const Duration(seconds: 60));
        expect(h.requests, hasLength(3));
        expect(h.store.savedCursor, const LogCursor('mem', 4));

        final delivered = h.deliveredMessages();
        expect(delivered.length, written.length);
        expect(delivered.toSet(), written.toSet());
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

    test('a network failure becomes a readable LogUploadException', () {
      fakeAsync((async) {
        final h = _Harness(async, throwOnRequest: true);
        h.write(1);

        Object? error;
        h.uploader.sendReport().catchError((Object e) {
          error = e;
          return '';
        });
        async.flushMicrotasks();

        expect(error, isA<LogUploadException>());
        expect(
          (error as LogUploadException).message,
          'Could not reach the relay. Check the connection and try again.',
        );
      });
    });
  });
}
