import 'dart:async';
import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/crash_reporting/crash_report.dart';
import 'package:player/core/crash_reporting/crash_reporter.dart';
import 'package:player/core/crash_reporting/startup_report_controller.dart';

const _context = CrashAppContext(
  version: '0.52.1',
  buildNumber: '5201',
  platform: 'android',
  osVersion: 'Android 15 (SDK 35)',
  environment: 'prod',
);

/// A one-frame trace whose top frame is `package:player/<file>:<line>`, so
/// each distinct (file, line) is a distinct crash site.
StackTrace _at(String file, int line) => StackTrace.fromString(
    '#0      Widget.method (package:player/$file:$line)\n');

class _Harness {
  _Harness(
    FakeAsync async, {
    bool consent = true,
    Future<bool> Function()? loadConsent,
    Future<void> Function(bool enabled)? saveConsent,
    Future<CrashAppContext> Function()? loadAppContext,
    List<int> statuses = const [201],
    bool isAvailable = true,
  }) {
    var call = 0;
    reporter = CrashReporter(
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, Object?>);
        final status =
            statuses[call < statuses.length ? call : statuses.length - 1];
        call++;
        return http.Response('{}', status);
      }),
      endpoint: Uri.parse('https://relay.test/crashes/report'),
      loadConsent: loadConsent ?? () async => consent,
      saveConsent: saveConsent ?? (enabled) async => saved.add(enabled),
      loadAppContext: loadAppContext ?? () async => _context,
      isAvailable: isAvailable,
      now: () => DateTime.utc(2026, 9, 10, 12).add(async.elapsed),
      presentFlutterError: presented.add,
    );
  }

  late final CrashReporter reporter;
  final requests = <Map<String, Object?>>[];
  final saved = <bool>[];
  final presented = <FlutterErrorDetails>[];

  Map<Object?, Object?> metadataOf(int index) =>
      requests[index]['metadata']! as Map<Object?, Object?>;
}

void main() {
  group('consent', () {
    test('sends nothing until the user opts in', () {
      fakeAsync((async) {
        final h = _Harness(async, consent: false);

        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();

        expect(h.requests, isEmpty);
      });
    });

    test('a consent read that throws counts as off and is retried next time',
        () {
      fakeAsync((async) {
        var reads = 0;
        final h = _Harness(
          async,
          loadConsent: () async {
            reads++;
            if (reads == 1) throw Exception('keyring locked');
            return true;
          },
        );

        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();
        expect(h.requests, isEmpty);

        h.reporter.report(StateError('x'), _at('b.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();
        expect(h.requests, hasLength(1));
        expect(reads, 2);
      });
    });

    test('a consent read slower than 2 seconds counts as off', () {
      fakeAsync((async) {
        final h = _Harness(async, loadConsent: () => Completer<bool>().future);

        var completed = false;
        h.reporter
            .report(StateError('x'), _at('a.dart', 1),
                capture: CrashCapture.zone)
            .then((_) => completed = true);
        async.elapse(const Duration(seconds: 3));

        expect(completed, isTrue);
        expect(h.requests, isEmpty);
      });
    });

    test('caches consent after the first successful read', () {
      fakeAsync((async) {
        var reads = 0;
        final h = _Harness(
          async,
          loadConsent: () async {
            reads++;
            return true;
          },
        );

        for (var i = 0; i < 3; i++) {
          h.reporter.report(StateError('x'), _at('f$i.dart', 1),
              capture: CrashCapture.zone);
          async.flushMicrotasks();
        }

        expect(reads, 1);
        expect(h.requests, hasLength(3));
      });
    });

    test('setEnabled stores the choice and applies it to the next report', () {
      fakeAsync((async) {
        final h = _Harness(async, consent: false);

        h.reporter.setEnabled(true);
        async.flushMicrotasks();
        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();

        expect(h.saved, [true]);
        expect(h.requests, hasLength(1));
      });
    });

    test('setEnabled keeps the old choice when storing fails', () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          consent: false,
          saveConsent: (_) async => throw Exception('keyring refused'),
        );

        Object? thrown;
        h.reporter.setEnabled(true).catchError((Object e) {
          thrown = e;
        });
        async.flushMicrotasks();
        bool? enabled;
        h.reporter.isEnabled().then((value) => enabled = value);
        async.flushMicrotasks();

        expect(thrown, isNotNull);
        expect(enabled, isFalse);
      });
    });

    test('a consent read in flight cannot undo an opt-out', () {
      fakeAsync((async) {
        final read = Completer<bool>();
        final h = _Harness(async, loadConsent: () => read.future);

        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();
        h.reporter.setEnabled(false);
        async.flushMicrotasks();
        // The stored value from before the opt-out arrives late.
        read.complete(true);
        async.flushMicrotasks();
        h.reporter.report(StateError('x'), _at('b.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();

        expect(h.requests, isEmpty);
      });
    });

    test('the later of two overlapping choices wins', () {
      fakeAsync((async) {
        final saves = <Completer<void>>[];
        final h = _Harness(
          async,
          consent: false,
          saveConsent: (_) {
            final save = Completer<void>();
            saves.add(save);
            return save.future;
          },
        );

        h.reporter.setEnabled(true);
        h.reporter.setEnabled(false);
        async.flushMicrotasks();
        saves[1].complete();
        saves[0].complete();
        async.flushMicrotasks();
        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();

        expect(h.requests, isEmpty);
      });
    });
  });

  group('payload', () {
    test('sends a sanitized player report', () {
      fakeAsync((async) {
        final h = _Harness(async);

        h.reporter.report(
          StateError(
              'stream https://mydia.example.org/api/stream/7?token=abc123 closed'),
          _at('core/player/player_controller.dart', 412),
          capture: CrashCapture.zone,
        );
        async.flushMicrotasks();

        final body = h.requests.single;
        expect(body['source'], 'player');
        expect(body['error_type'], 'StateError');
        expect(
          body['error_message'],
          'Bad state: stream https://[HOST]/api/stream/7?[REDACTED] closed',
        );
        expect(body['version'], '0.52.1');
        expect(h.metadataOf(0)['capture'], 'zone');
        expect(h.metadataOf(0)['manual'], isFalse);
        expect(h.metadataOf(0)['platform'], 'android');
        expect(
          h.metadataOf(0)['file'],
          'package:player/core/player/player_controller.dart',
        );
      });
    });
  });

  group('volume', () {
    test('drops reports past 10 in a minute', () {
      fakeAsync((async) {
        final h = _Harness(async);

        for (var i = 0; i < 11; i++) {
          h.reporter.report(StateError('x'), _at('f$i.dart', 1),
              capture: CrashCapture.zone);
          async.flushMicrotasks();
        }
        expect(h.requests, hasLength(10));

        async.elapse(const Duration(seconds: 61));
        h.reporter.report(StateError('x'), _at('late.dart', 1),
            capture: CrashCapture.zone);
        async.flushMicrotasks();
        expect(h.requests, hasLength(11));
      });
    });

    test('reports a crash site once per session', () {
      fakeAsync((async) {
        final h = _Harness(async);

        for (var i = 0; i < 3; i++) {
          h.reporter.report(StateError('x$i'), _at('a.dart', 1),
              capture: CrashCapture.zone);
          async.flushMicrotasks();
        }

        expect(h.requests, hasLength(1));
      });
    });

    test('dedups frameless errors on type and message', () {
      fakeAsync((async) {
        final h = _Harness(async);

        h.reporter.report(StateError('a'), null, capture: CrashCapture.zone);
        async.flushMicrotasks();
        h.reporter.report(StateError('a'), null, capture: CrashCapture.zone);
        async.flushMicrotasks();
        h.reporter.report(StateError('b'), null, capture: CrashCapture.zone);
        async.flushMicrotasks();

        expect(h.requests, hasLength(2));
      });
    });
  });

  group('handlers', () {
    test('handleFlutterError presents the error, then reports it', () {
      fakeAsync((async) {
        final h = _Harness(async);

        h.reporter.handleFlutterError(
          FlutterErrorDetails(
              exception: StateError('x'), stack: _at('a.dart', 1)),
        );
        async.flushMicrotasks();

        expect(h.presented, hasLength(1));
        expect(h.metadataOf(0)['capture'], 'flutter_error');
      });
    });

    test('handleFlutterError presents silent errors but does not report them',
        () {
      fakeAsync((async) {
        final h = _Harness(async);

        h.reporter.handleFlutterError(
          FlutterErrorDetails(
            exception: StateError('image failed'),
            stack: _at('a.dart', 1),
            silent: true,
          ),
        );
        async.flushMicrotasks();

        expect(h.presented, hasLength(1));
        expect(h.requests, isEmpty);
      });
    });

    test('handlePlatformError reports and marks the error handled', () {
      fakeAsync((async) {
        final h = _Harness(async);

        final handled =
            h.reporter.handlePlatformError(StateError('x'), _at('a.dart', 1));
        async.flushMicrotasks();

        expect(handled, isTrue);
        expect(h.metadataOf(0)['capture'], 'platform_dispatcher');
      });
    });

    test('install routes both handlers to the reporter', () {
      final originalFlutter = FlutterError.onError;
      final originalPlatform = PlatformDispatcher.instance.onError;
      addTearDown(() {
        FlutterError.onError = originalFlutter;
        PlatformDispatcher.instance.onError = originalPlatform;
      });

      fakeAsync((async) {
        final h = _Harness(async);
        h.reporter.install();

        expect(FlutterError.onError, h.reporter.handleFlutterError);
        expect(PlatformDispatcher.instance.onError,
            h.reporter.handlePlatformError);
      });
    });

    test('an error raised while reporting is contained', () {
      fakeAsync((async) {
        final h = _Harness(
          async,
          loadAppContext: () async => throw StateError('no package info'),
        );

        var completed = false;
        h.reporter
            .report(StateError('x'), _at('a.dart', 1),
                capture: CrashCapture.zone)
            .then((_) => completed = true);
        async.flushMicrotasks();

        expect(completed, isTrue);
        expect(h.requests, isEmpty);
      });
    });

    test('an unavailable reporter sends nothing and offers no startup report',
        () {
      fakeAsync((async) {
        final h = _Harness(async, isAvailable: false);

        h.reporter.report(StateError('x'), _at('a.dart', 1),
            capture: CrashCapture.zone);
        final controller =
            h.reporter.reportStartupFailure(StateError('x'), _at('a.dart', 1));
        bool? enabled;
        h.reporter.isEnabled().then((value) => enabled = value);
        async.flushMicrotasks();

        expect(h.requests, isEmpty);
        expect(controller, isNull);
        expect(enabled, isFalse);
      });
    });
  });

  group('reportStartupFailure', () {
    test('sends at once when the user has opted in', () {
      fakeAsync((async) {
        final h = _Harness(async);

        final controller = h.reporter.reportStartupFailure(
          StateError('bridge'),
          _at('main.dart', 124),
        )!;
        async.flushMicrotasks();

        expect(controller.value, StartupReportState.sent);
        expect(h.metadataOf(0)['capture'], 'startup');
        expect(h.metadataOf(0)['manual'], isFalse);
      });
    });

    test('waits for a tap when the user has not opted in', () {
      fakeAsync((async) {
        final h = _Harness(async, consent: false);

        final controller = h.reporter.reportStartupFailure(
          StateError('bridge'),
          _at('main.dart', 124),
        )!;
        async.flushMicrotasks();
        expect(controller.value, StartupReportState.idle);
        expect(h.requests, isEmpty);

        controller.send();
        async.flushMicrotasks();

        expect(controller.value, StartupReportState.sent);
        expect(h.metadataOf(0)['manual'], isTrue);
      });
    });

    test('a failed send can be retried', () {
      fakeAsync((async) {
        final h = _Harness(async, consent: false, statuses: [503, 201]);

        final controller = h.reporter.reportStartupFailure(
          StateError('bridge'),
          _at('main.dart', 124),
        )!;
        controller.send();
        async.flushMicrotasks();
        expect(controller.value, StartupReportState.failed);

        controller.send();
        async.flushMicrotasks();
        expect(controller.value, StartupReportState.sent);
        expect(h.requests, hasLength(2));
      });
    });

    test('skips the throttle and the session dedup', () {
      fakeAsync((async) {
        final h = _Harness(async);

        for (var i = 0; i < 11; i++) {
          h.reporter.report(StateError('x'), _at('f$i.dart', 1),
              capture: CrashCapture.zone);
          async.flushMicrotasks();
        }
        expect(h.requests, hasLength(10));

        // f0.dart:1 was reported above, and the window is spent.
        h.reporter.reportStartupFailure(StateError('x'), _at('f0.dart', 1));
        async.flushMicrotasks();

        expect(h.requests, hasLength(11));
        expect(h.metadataOf(10)['capture'], 'startup');
      });
    });
  });
}
