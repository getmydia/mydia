import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/crash_reporting/crash_report_queue.dart';

final _endpoint = Uri.parse('https://relay.test/crashes/report');
final _start = DateTime.utc(2026, 9, 10, 12);

CrashReportQueue _queue(
  FakeAsync async,
  http.Client client, {
  int maxLength = 20,
}) =>
    CrashReportQueue(
      client: client,
      endpoint: _endpoint,
      now: () => _start.add(async.elapsed),
      maxLength: maxLength,
    );

void main() {
  group('SendResult.fromStatus', () {
    test('maps the statuses the relays answer with', () {
      expect(SendResult.fromStatus(201).outcome, SendOutcome.sent);
      expect(SendResult.fromStatus(400).outcome, SendOutcome.rejected);
      expect(SendResult.fromStatus(429).outcome, SendOutcome.rateLimited);
      expect(SendResult.fromStatus(500).outcome, SendOutcome.failed);
      expect(SendResult.fromStatus(503).outcome, SendOutcome.failed);
    });

    test('reads retry-after as whole seconds only', () {
      expect(
        SendResult.fromStatus(429, retryAfterHeader: '60').retryAfter,
        const Duration(seconds: 60),
      );
      expect(
        SendResult.fromStatus(429,
                retryAfterHeader: 'Wed, 21 Oct 2026 07:28:00 GMT')
            .retryAfter,
        isNull,
      );
      expect(
        SendResult.fromStatus(429, retryAfterHeader: '0').retryAfter,
        isNull,
      );
    });
  });

  test('backoff doubles from 60 seconds and holds at 8 minutes', () {
    expect(
      [for (var n = 1; n <= 6; n++) CrashReportQueue.backoffAfter(n).inSeconds],
      [60, 120, 240, 480, 480, 480],
    );
  });

  test('posts the body as JSON and empties the queue on a 201', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final queue = _queue(
        async,
        MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 201);
        }),
      );

      queue.enqueue({'error_type': 'StateError'});
      async.flushMicrotasks();

      expect(requests, hasLength(1));
      expect(requests.single.method, 'POST');
      expect(requests.single.url, _endpoint);
      expect(requests.single.headers['content-type'],
          startsWith('application/json'));
      expect(jsonDecode(requests.single.body), {'error_type': 'StateError'});
      expect(queue.length, 0);
    });
  });

  test('drops a report the relay rejects with a 400', () {
    fakeAsync((async) {
      var calls = 0;
      final queue = _queue(
        async,
        MockClient((_) async {
          calls++;
          return http.Response('{}', 400);
        }),
      );

      queue.enqueue({'n': 1});
      async.elapse(const Duration(hours: 1));

      expect(calls, 1);
      expect(queue.length, 0);
    });
  });

  test('retries failures on the backoff schedule', () {
    fakeAsync((async) {
      final attempts = <Duration>[];
      final queue = _queue(
        async,
        MockClient((_) async {
          attempts.add(async.elapsed);
          return http.Response('', 503);
        }),
      );

      queue.enqueue({'n': 1});
      async.elapse(const Duration(minutes: 30));

      expect(attempts.map((d) => d.inSeconds), [0, 60, 180, 420, 900, 1380]);
    });
  });

  test('gives up after 10 failed attempts', () {
    fakeAsync((async) {
      var calls = 0;
      final queue = _queue(
        async,
        MockClient((_) async {
          calls++;
          return http.Response('', 500);
        }),
      );

      queue.enqueue({'n': 1});
      async.elapse(const Duration(hours: 2));

      expect(calls, 10);
      expect(queue.length, 0);
    });
  });

  test('honours retry-after, and gives up on a report older than 24 hours', () {
    fakeAsync((async) {
      final attempts = <Duration>[];
      final queue = _queue(
        async,
        MockClient((_) async {
          attempts.add(async.elapsed);
          return http.Response('', 429, headers: {'retry-after': '36000'});
        }),
      );

      queue.enqueue({'n': 1});
      async.elapse(const Duration(hours: 31));

      expect(attempts.map((d) => d.inHours), [0, 10, 20, 30]);
      expect(queue.length, 0);
    });
  });

  test('a 429 without a usable retry-after falls back to the backoff', () {
    fakeAsync((async) {
      final attempts = <Duration>[];
      _queue(
        async,
        MockClient((_) async {
          attempts.add(async.elapsed);
          return http.Response('', 429);
        }),
      ).enqueue({'n': 1});

      async.elapse(const Duration(seconds: 90));

      expect(attempts.map((d) => d.inSeconds), [0, 60]);
    });
  });

  test('a network error counts as a failure', () {
    fakeAsync((async) {
      final attempts = <Duration>[];
      _queue(
        async,
        MockClient((_) async {
          attempts.add(async.elapsed);
          throw http.ClientException('connection refused');
        }),
      ).enqueue({'n': 1});

      async.elapse(const Duration(seconds: 90));

      expect(attempts.map((d) => d.inSeconds), [0, 60]);
    });
  });

  test('a request that hangs times out after 10 seconds and is retried', () {
    fakeAsync((async) {
      final attempts = <Duration>[];
      _queue(
        async,
        MockClient((_) {
          attempts.add(async.elapsed);
          return Completer<http.Response>().future;
        }),
      ).enqueue({'n': 1});

      async.elapse(const Duration(seconds: 75));

      expect(attempts.map((d) => d.inSeconds), [0, 70]);
    });
  });

  test('holds at most maxLength reports, dropping the oldest', () {
    fakeAsync((async) {
      var online = false;
      final delivered = <Object?>[];
      final queue = _queue(
        async,
        MockClient((request) async {
          if (!online) return http.Response('', 503);
          delivered.add((jsonDecode(request.body) as Map)['n']);
          return http.Response('{}', 201);
        }),
        maxLength: 3,
      );

      for (var n = 1; n <= 5; n++) {
        queue.enqueue({'n': n});
        async.flushMicrotasks();
      }
      expect(queue.length, 3);

      online = true;
      async.elapse(const Duration(minutes: 2));

      expect(delivered, [3, 4, 5]);
      expect(queue.length, 0);
    });
  });

  test('sendOnce makes one attempt and never queues', () {
    fakeAsync((async) {
      var calls = 0;
      final queue = _queue(
        async,
        MockClient((_) async {
          calls++;
          return http.Response('', 503);
        }),
      );

      SendResult? result;
      queue.sendOnce({'n': 1}).then((r) => result = r);
      async.elapse(const Duration(minutes: 10));

      expect(result?.outcome, SendOutcome.failed);
      expect(calls, 1);
      expect(queue.length, 0);
    });
  });
}
