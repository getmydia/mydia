import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/stream_urls.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../presentation/screens/player/player_screen_test_harness.dart';
import '../../test_utils/scripted_mydia_transport.dart';
import '../sources/mydia/fake_mydia_client.dart';

const _endOk = {'__typename': 'RootMutationType', 'endStreamingSession': true};

/// Routes by operation: EndStreamingSession answers [end], and either start
/// document answers from [starts] by call index.
ScriptedMydiaTransport _server(
    {required List<Object> starts, Object end = _endOk}) {
  var next = 0;
  return ScriptedMydiaTransport((request, _) {
    if (request.operation == 'EndStreamingSession') return end;
    final i = next < starts.length ? next++ : starts.length - 1;
    return starts[i];
  });
}

class _Urls implements StreamUrls {
  @override
  Future<ResolvedSource> directPlay(String fileId) async =>
      ResolvedSource(url: 'direct://$fileId', headers: const {'X': '1'});

  @override
  ResolvedSource hls(String sessionId) => ResolvedSource(
      url: 'hls://$sessionId',
      headers: const {},
      probeHeaders: const {'A': 'b'});

  @override
  ResolvedSource hlsFile(String sessionId, String name) => ResolvedSource(
      url: 'hls://$sessionId/$name',
      headers: const {},
      probeHeaders: const {'A': 'b'});
}

Future<({int status, String body})> _readyProbe(
        String url, Map<String, String>? headers) async =>
    (status: 200, body: 'a.ts\nb.ts\nc.ts\n#EXT-X-ENDLIST\n');

Future<({int status, String body})> _growingProbe(
        String url, Map<String, String>? headers) async =>
    (status: 200, body: 'a.ts\nb.ts\nc.ts\n');

PlaybackController _controller(
  ScriptedMydiaTransport server, {
  bool relayed = false,
  PlaylistProbe probe = _readyProbe,
  Duration firstAdvanceTimeout = const Duration(seconds: 60),
}) =>
    PlaybackController(
      client: fakeMydiaClient(server),
      urls: _Urls(),
      relayed: relayed,
      probe: probe,
      wait: (_) async {},
      firstAdvanceTimeout: firstAdvanceTimeout,
    );

const _copy = HlsPlan(
  strategy: HlsStrategy.copy,
  rung: QualityRung.original,
  adaptive: false,
  reason: PlanReason.copyAccepted,
);

const _transcode480 = HlsPlan(
  strategy: HlsStrategy.transcode,
  rung: QualityRung(label: '480p', height: 480, maxBitrateKbps: 1500),
  adaptive: false,
  reason: PlanReason.fixedRungRequested,
);

const _direct = DirectPlayPlan(reason: PlanReason.directPlayAccepted);

ScriptedMydiaTransport _delayedStartServer({
  required Future<Map<String, dynamic>> Function(int index) start,
  void Function(String sessionId)? onEnd,
}) {
  var starts = 0;
  return ScriptedMydiaTransport((request, _) async {
    final sessionId = request.variables['sessionId'] as String?;
    if (sessionId == null) return await start(starts++);
    onEnd?.call(sessionId);
    return _endOk;
  });
}

void main() {
  group('open', () {
    test('direct play resolves a URL and starts no session', () async {
      final server = _server(starts: const []);
      final controller = _controller(server);
      final source = await controller.open(_direct,
          fileId: 'file-1',
          startAt: const Duration(seconds: 90),
          totalDuration: const Duration(minutes: 40));
      expect(source.url, 'direct://file-1');
      expect(source.headers, {'X': '1'});
      expect(source.seekOnOpen, isTrue);
      expect(source.fullPlaylist, isFalse);
      expect(source.sessionId, isNull);
      expect(source.timeline.startOffset, Duration.zero);
      expect(source.timeline.totalDuration, const Duration(minutes: 40));
      expect(controller.sessionId, isNull);
      expect(server.requests, isEmpty);
    });

    test('a copy session asks for HLS_COPY, FULL, no caps', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 's1', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      final vars = server.requests.single.variables;
      expect(vars['strategy'], 'HLS_COPY');
      expect(vars['maxBitrate'], isNull);
      expect(vars['maxHeight'], isNull);
      expect(vars['startPosition'], isNull);
      expect(vars['playlistMode'], 'FULL');
      expect(source.sessionId, 's1');
      expect(controller.sessionId, 's1');
      expect(source.url, 'hls://s1');
      expect(source.fullPlaylist, isTrue);
      expect(source.seekOnOpen, isTrue);
      expect(source.timeline.startOffset, Duration.zero);
      expect(source.effectiveRung, QualityRung.original);
    });

    test('a WINDOW answer carries the echoed offset and seeks nothing',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', startPosition: 598, duration: 2400),
      ]);
      final controller = _controller(server);
      final source = await controller.open(_transcode480,
          fileId: 'file-1', startAt: const Duration(seconds: 600));
      expect(server.requests.single.variables['startPosition'], 600);
      expect(server.requests.single.variables['strategy'], 'TRANSCODE');
      expect(source.fullPlaylist, isFalse);
      expect(source.seekOnOpen, isFalse);
      expect(source.timeline.startOffset, const Duration(seconds: 598));
      expect(source.timeline.totalDuration, const Duration(seconds: 2400));
    });

    test('a fixed rung sends its caps; a relay tightens them', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', maxBitrate: 1500, maxHeight: 480),
      ]);
      final controller = _controller(server, relayed: true);
      final source = await controller.open(_transcode480,
          fileId: 'file-1', startAt: Duration.zero);
      expect(server.requests.single.variables['maxBitrate'], 1500);
      expect(server.requests.single.variables['maxHeight'], 480);
      expect(source.effectiveRung?.label, '480p');
    });

    test('a relay caps an Original copy request to 3000 kbps and 720p',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', maxBitrate: 3000, maxHeight: 720),
      ]);
      final controller = _controller(server, relayed: true);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      expect(server.requests.single.variables['maxBitrate'], 3000);
      expect(server.requests.single.variables['maxHeight'], 720);
      expect(source.effectiveRung?.label, '720p');
    });

    test('an old server without maxHeight is retried with the legacy document',
        () async {
      final server = _server(starts: [
        graphqlError('Unknown argument "maxHeight" on field '
            '"startStreamingSession" of type "RootMutationType".'),
        legacyStartStreamingSessionResponse(sessionId: 's1'),
      ]);
      final controller = _controller(server);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      expect(server.requests, hasLength(2));
      expect(server.requests.first.operation, 'StartStreamingSession');
      expect(server.requests.last.operation, 'StartStreamingSessionLegacy');
      expect(server.requests.last.variables.containsKey('maxHeight'), isFalse);
      expect(
          server.requests.last.variables.containsKey('playlistMode'), isFalse);
      expect(source.sessionId, 's1');
      expect(source.fullPlaylist, isFalse);
      // The legacy document echoes no caps, so nothing is claimed.
      expect(source.effectiveRung, isNull);

      // The next open skips straight to the legacy document.
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      expect(server.requests, hasLength(3));
      expect(server.requests.last.operation, 'StartStreamingSessionLegacy');
      expect(server.requests.last.variables.containsKey('maxHeight'), isFalse);
    });

    test('a genuine mutation failure is thrown, not retried', () async {
      final server = _server(starts: [graphqlError('Media file not found')]);
      final controller = _controller(server);
      await expectLater(
        controller.open(_copy, fileId: 'file-1', startAt: Duration.zero),
        throwsA(isA<Exception>()),
      );
      expect(server.requests, hasLength(1));
      expect(controller.sessionId, isNull);
    });

    test('the playlist probe is polled until it lists three segments',
        () async {
      var polls = 0;
      Future<({int status, String body})> probe(
          String url, Map<String, String>? headers) async {
        polls++;
        expect(headers, {'A': 'b'});
        if (polls == 1) return (status: 404, body: '');
        if (polls == 2) return (status: 200, body: 'a.ts\n');
        return (status: 200, body: 'a.ts\nb.ts\nc.ts\n');
      }

      final server =
          _server(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      final controller = _controller(server, probe: probe);
      final messages = <String>[];
      await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero, onProgress: messages.add);
      expect(polls, 3);
      expect(messages, contains('Preparing stream... 33%'));
    });

    test(
        'a FULL session is still probed once: the probe is its first-fetch retry',
        () async {
      var polls = 0;
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 's1', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server, probe: (url, headers) async {
        polls++;
        return (status: 200, body: 'a.ts\nb.ts\nc.ts\n#EXT-X-ENDLIST\n');
      });
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      expect(polls, 1);
    });

    test('a playlist that never becomes ready ends its session', () async {
      final server =
          _server(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      var polls = 0;
      final delays = <Duration>[];
      final controller = PlaybackController(
        client: fakeMydiaClient(server),
        urls: _Urls(),
        relayed: false,
        probe: (_, __) async {
          polls++;
          throw StateError('manifest unavailable');
        },
        wait: (delay) async => delays.add(delay),
      );

      await expectLater(
        controller.open(_copy, fileId: 'file-1', startAt: Duration.zero),
        throwsA(isA<Exception>()),
      );
      expect(polls, 20);
      expect(delays.take(5), const [
        Duration(milliseconds: 500),
        Duration(milliseconds: 1250),
        Duration(milliseconds: 2000),
        Duration(milliseconds: 2750),
        Duration(milliseconds: 3000),
      ]);
      expect(delays.skip(5), everyElement(const Duration(seconds: 3)));
      expect(controller.sessionId, isNull);
      expect(server.requests.last.variables['sessionId'], 's1');
    });

    for (final message in [
      'Cannot query field "maxHeight" on type "StreamingSessionResult".',
      'Unknown argument "playlistMode" on field "startStreamingSession".',
      'Cannot query field "playlistMode" on type "StreamingSessionResult".',
    ]) {
      test('uses the legacy document for $message', () async {
        final server = _server(starts: [
          graphqlError(message),
          legacyStartStreamingSessionResponse(
            sessionId: 'legacy',
            startPosition: 298,
            duration: 2400,
          ),
        ]);
        final source = await _controller(server).open(
          _transcode480,
          fileId: 'file-1',
          startAt: const Duration(seconds: 300),
        );
        expect(server.requests, hasLength(2));
        expect(server.requests.last.variables, {
          'fileId': 'file-1',
          'strategy': 'TRANSCODE',
          'maxBitrate': 1500,
          'startPosition': 300,
        });
        expect(source.timeline.startOffset, const Duration(seconds: 298));
        expect(source.timeline.totalDuration, const Duration(seconds: 2400));
        expect(source.seekOnOpen, isFalse);
        expect(source.effectiveRung, isNull);
      });
    }

    for (final failure in <Object>[
      graphqlError('Unauthorized to set maxHeight or playlistMode'),
      const SourceException.unreachable(),
    ]) {
      test(
          'does not classify resolver or transport errors as schema skew: '
          '$failure', () async {
        final server = _server(starts: [failure]);
        await expectLater(
          _controller(server).open(
            _copy,
            fileId: 'file-1',
            startAt: Duration.zero,
          ),
          throwsA(isA<Exception>()),
        );
        expect(server.requests, hasLength(1));
        expect(server.requests.single.operation, 'StartStreamingSession');
      });
    }

    test('FULL ignores the echoed offset and preserves the known runtime',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(
          playlistMode: 'FULL',
          startPosition: 598,
          duration: 1800,
        )
      ]);
      final source = await _controller(server).open(
        _copy,
        fileId: 'file-1',
        startAt: const Duration(seconds: 600),
        totalDuration: const Duration(seconds: 2400),
      );
      expect(source.timeline.startOffset, Duration.zero);
      expect(source.timeline.totalDuration, const Duration(seconds: 2400));
      expect(source.seekOnOpen, isTrue);
    });

    test(
        'a FULL answer whose playlist never ends is opened as a window at the '
        'resume position', () async {
      // A server that serves FFmpeg's own growing playlist over p2p while
      // still answering FULL. Trusting the mode put the bar at zero on the
      // resume point and saved that over the real position.
      final server = _server(starts: [
        startStreamingSessionResponse(
          playlistMode: 'FULL',
          startPosition: 0,
          duration: 2400,
        )
      ]);
      final source = await _controller(server, probe: _growingProbe).open(
        _transcode480,
        fileId: 'file-1',
        startAt: const Duration(seconds: 600),
      );
      expect(source.fullPlaylist, isFalse);
      expect(source.seekOnOpen, isFalse);
      expect(source.timeline.startOffset, const Duration(seconds: 600));
      expect(source.timeline.totalDuration, const Duration(seconds: 2400));
    });

    test('a FULL answer starting at zero keeps a zero offset either way',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(playlistMode: 'FULL', duration: 2400)
      ]);
      final source = await _controller(server, probe: _growingProbe)
          .open(_transcode480, fileId: 'file-1', startAt: Duration.zero);
      expect(source.timeline.startOffset, Duration.zero);
    });
  });

  group('sessionFile', () {
    test('is null in direct play, which has no session', () async {
      final controller = _controller(_server(starts: const []));
      await controller.open(_direct, fileId: 'file-1', startAt: Duration.zero);
      expect(controller.sessionFile('subs_3.mks'), isNull);
    });

    test('addresses a file in the live session the way its playlist is',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 's1', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);

      final file = controller.sessionFile('subs_3.mks');
      expect(file?.url, 'hls://s1/subs_3.mks');
      expect(file?.probeHeaders, {'A': 'b'});
    });
  });

  group('replaceSource', () {
    test('a failed playlist ends the new session and keeps the old', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old'),
        startStreamingSessionResponse(sessionId: 'new'),
      ]);
      final controller = _controller(server, probe: (url, headers) async {
        if (url == 'hls://old') return _readyProbe(url, headers);
        return (status: 404, body: '');
      });
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      await expectLater(
        controller.replaceSource(
          _transcode480,
          fileId: 'file-1',
          realPosition: const Duration(seconds: 300),
          attach: (_) async => throw StateError('must not attach'),
        ),
        throwsA(isA<Exception>()),
      );
      expect(controller.sessionId, 'old');
      expect(controller.switching, isFalse);
      expect(server.requests.last.variables['sessionId'], 'new');
    });

    test('waits the full 60 seconds before timing out a switch', () {
      fakeAsync((clock) {
        final server = _server(starts: [
          startStreamingSessionResponse(sessionId: 'old'),
          startStreamingSessionResponse(sessionId: 'new'),
        ]);
        final controller = _controller(server);
        unawaited(
            controller.open(_copy, fileId: 'file-1', startAt: Duration.zero));
        clock.flushMicrotasks();
        expect(controller.sessionId, 'old');
        // Keep cancellation in this fake-clock zone. A broadcast stream's
        // cancel() returns Dart's shared future from the outer real zone.
        final positions = StreamController<Duration>(onCancel: () async {});
        Object? failure;
        unawaited(controller
            .replaceSource(
          _transcode480,
          fileId: 'file-1',
          realPosition: Duration.zero,
          attach: (_) async => positions.stream,
        )
            .then<void>(
          (_) => fail('A stalled source must not finish switching'),
          onError: (Object error) {
            failure = error;
          },
        ));
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 59));
        expect(controller.switching, isTrue);
        expect(server.requests, hasLength(2));
        expect(failure, isNull);
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(failure, isA<TimeoutException>());
        expect(controller.switching, isFalse);
        expect(controller.sessionId, 'old');
        expect(server.requests.last.variables['sessionId'], 'new');
        expect(positions.hasListener, isFalse);
        unawaited(positions.close());
        clock.flushMicrotasks();
      });
    });

    test('switching to direct play ends the old session after advancement',
        () async {
      final server =
          _server(starts: [startStreamingSessionResponse(sessionId: 'old')]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final source = await controller.replaceSource(
        _direct,
        fileId: 'file-1',
        realPosition: const Duration(seconds: 300),
        attach: (source) async {
          expect(source.seekOnOpen, isTrue);
          expect(server.requests, hasLength(1));
          return Stream.fromIterable(const [
            Duration(seconds: 300),
            Duration(seconds: 301),
          ]);
        },
      );
      expect(source.url, 'direct://file-1');
      expect(controller.sessionId, isNull);
      expect(server.requests.last.variables['sessionId'], 'old');
    });
    test('starts the new session, attaches, waits, then ends the old one',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);

      final listening = Completer<void>();
      final positions = StreamController<Duration>.broadcast(
        onListen: listening.complete,
      );
      addTearDown(positions.close);
      final log = <String>[];
      final attached = Completer<void>();
      final switched = controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: const Duration(seconds: 300),
        attach: (source) async {
          log.add(
              'attach ${source.sessionId} switching=${controller.switching}');
          attached.complete();
          return positions.stream;
        },
      );
      await attached.future;
      expect(log, ['attach new switching=true']);
      // Nothing ended yet: the old frames are still on screen.
      expect(
          server.requests.map((r) => r.variables['sessionId']), [null, null]);

      await listening.future;
      positions.add(const Duration(seconds: 300));
      positions.add(const Duration(seconds: 301));
      final source = await switched;

      expect(source.sessionId, 'new');
      expect(controller.sessionId, 'new');
      expect(controller.switching, isFalse);
      expect(server.requests.last.variables['sessionId'], 'old');
      expect(server.requests.map((r) => r.variables['fileId']),
          ['file-1', 'file-1', null]);
    });

    test('a switch from direct play ends nothing and records the session',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      await controller.open(_direct, fileId: 'file-1', startAt: Duration.zero);
      await controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: const Duration(seconds: 10),
        attach: (_) async => Stream.fromIterable(
            const [Duration(seconds: 10), Duration(seconds: 11)]),
      );
      expect(controller.sessionId, 'new');
      expect(server.requests.map((r) => r.variables['sessionId']), [null]);
    });

    test('an attach that fails ends the new session and keeps the old',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      await expectLater(
        controller.replaceSource(
          _transcode480,
          fileId: 'file-1',
          realPosition: Duration.zero,
          attach: (_) async => throw StateError('open failed'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(controller.sessionId, 'old');
      expect(controller.switching, isFalse);
      expect(server.requests.last.variables['sessionId'], 'new');
    });

    test('a source that never advances times out and keeps the old session',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server,
          firstAdvanceTimeout: const Duration(milliseconds: 20));
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final stuck = StreamController<Duration>.broadcast();
      addTearDown(stuck.close);
      await expectLater(
        controller.replaceSource(
          _transcode480,
          fileId: 'file-1',
          realPosition: Duration.zero,
          attach: (_) async => stuck.stream,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(controller.sessionId, 'old');
    });

    test('a second switch while one is in flight is refused', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final positions = StreamController<Duration>.broadcast();
      addTearDown(positions.close);
      final attached = Completer<void>();
      final first = controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: Duration.zero,
        attach: (_) async {
          attached.complete();
          return positions.stream;
        },
      );
      await attached.future;
      await expectLater(
        controller.replaceSource(
          _transcode480,
          fileId: 'file-1',
          realPosition: Duration.zero,
          attach: (_) async => positions.stream,
        ),
        throwsA(isA<StateError>()),
      );
      positions.add(Duration.zero);
      positions.add(const Duration(seconds: 1));
      await first;
    });
  });

  group('endSession', () {
    test('cleans up an initial start that returns after teardown', () async {
      final requested = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      final ended = Completer<void>();
      final server = _delayedStartServer(
        start: (_) {
          requested.complete();
          return response.future;
        },
        onEnd: (_) => ended.complete(),
      );
      final controller = _controller(server);
      final opened = controller
          .open(_copy, fileId: 'file-1', startAt: Duration.zero)
          .then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
      await requested.future;
      await controller.endSession();
      response.complete(startStreamingSessionResponse(sessionId: 'late'));

      expect(await opened, isA<StateError>());
      await ended.future;
      expect(controller.sessionId, isNull);
      expect(server.requests.map((request) => request.variables['sessionId']),
          [null, 'late']);
    });

    test('ends the retained old session and a late replacement start',
        () async {
      final requested = Completer<void>();
      final response = Completer<Map<String, dynamic>>();
      final lateEnded = Completer<void>();
      final server = _delayedStartServer(
        start: (index) {
          if (index == 0) {
            return Future.value(
                startStreamingSessionResponse(sessionId: 'old'));
          }
          requested.complete();
          return response.future;
        },
        onEnd: (id) {
          if (id == 'late') lateEnded.complete();
        },
      );
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      var attached = false;
      final switched = controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: Duration.zero,
        attach: (_) async {
          attached = true;
          return Stream.fromIterable(
              const [Duration.zero, Duration(seconds: 1)]);
        },
      ).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await requested.future;
      await controller.endSession();
      final endedBeforeResponse = server.requests
          .map((request) => request.variables['sessionId'])
          .whereType<String>()
          .toList();
      response.complete(startStreamingSessionResponse(sessionId: 'late'));

      expect(await switched, isA<StateError>());
      await lateEnded.future;
      expect(endedBeforeResponse, ['old']);
      expect(attached, isFalse);
      expect(controller.sessionId, isNull);
      expect(controller.switching, isFalse);
      expect(
          server.requests
              .map((request) => request.variables['sessionId'])
              .whereType<String>(),
          ['old', 'late']);
    });

    test('ends both sessions without restoring old after an advance wait',
        () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old'),
        startStreamingSessionResponse(sessionId: 'new'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final listening = Completer<void>();
      final positions = StreamController<Duration>.broadcast(
        onListen: listening.complete,
      );
      final switched = controller
          .replaceSource(
            _transcode480,
            fileId: 'file-1',
            realPosition: Duration.zero,
            attach: (_) async => positions.stream,
          )
          .then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
      await listening.future;
      await controller.endSession();
      final retainedListener = positions.hasListener;
      await positions.close();

      expect(await switched, isA<StateError>());
      expect(controller.sessionId, isNull);
      expect(controller.switching, isFalse);
      expect(retainedListener, isFalse);
      expect(
          server.requests
              .map((request) => request.variables['sessionId'])
              .whereType<String>(),
          unorderedEquals(['old', 'new']));
      await controller.endSession();
      expect(server.requests, hasLength(4));
    });

    test('a delayed attach cannot finish a switch after teardown', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old'),
        startStreamingSessionResponse(sessionId: 'new'),
      ]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final attaching = Completer<void>();
      final attached = Completer<Stream<Duration>>();
      final switched = controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: Duration.zero,
        attach: (_) {
          attaching.complete();
          return attached.future;
        },
      ).then<Object?>(
        (_) => null,
        onError: (Object error) => error,
      );
      await attaching.future;
      await controller.endSession();
      attached.complete(Stream.fromIterable(const [
        Duration.zero,
        Duration(seconds: 1),
      ]));

      expect(await switched, isA<StateError>());
      expect(controller.sessionId, isNull);
      expect(controller.switching, isFalse);
      expect(
          server.requests
              .map((request) => request.variables['sessionId'])
              .whereType<String>(),
          unorderedEquals(['old', 'new']));
    });

    test('a torn-down playlist cannot replace a later open', () async {
      final server = _server(starts: [
        startStreamingSessionResponse(sessionId: 'old'),
        startStreamingSessionResponse(sessionId: 'current'),
      ]);
      final probing = Completer<void>();
      final probeResult = Completer<({int status, String body})>();
      final controller = _controller(server, probe: (url, headers) {
        if (url == 'hls://old') {
          probing.complete();
          return probeResult.future;
        }
        return _readyProbe(url, headers);
      });
      final oldOpen = controller
          .open(_copy, fileId: 'file-1', startAt: Duration.zero)
          .then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
      await probing.future;
      await controller.endSession();
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      probeResult.complete((status: 200, body: 'a.ts\nb.ts\nc.ts\n'));

      expect(await oldOpen, isA<StateError>());
      expect(controller.sessionId, 'current');
      expect(
          server.requests
              .map((request) => request.variables['sessionId'])
              .whereType<String>(),
          ['old']);
      await controller.endSession();
      expect(
          server.requests
              .map((request) => request.variables['sessionId'])
              .whereType<String>(),
          ['old', 'current']);
    });

    test('tolerates a failed end', () async {
      final server = _server(
          starts: [startStreamingSessionResponse(sessionId: 's1')],
          end: graphqlError('Already ended'));
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      await controller.endSession();
      expect(controller.sessionId, isNull);
      expect(
          server.of('EndStreamingSession').single.variables['sessionId'], 's1');
    });

    test('ends the current session once, then is a no-op', () async {
      final server =
          _server(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      final controller = _controller(server);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      await controller.endSession();
      await controller.endSession();
      expect(controller.sessionId, isNull);
      expect(server.requests.where((r) => r.variables.containsKey('sessionId')),
          hasLength(1));
    });
  });

  group('awaitFirstAdvance', () {
    test('completes on the first position past the first one seen', () async {
      final positions = StreamController<Duration>.broadcast();
      addTearDown(positions.close);
      final done = awaitFirstAdvance(positions.stream,
          timeout: const Duration(seconds: 5));
      positions.add(const Duration(seconds: 300));
      positions.add(const Duration(seconds: 300));
      positions.add(const Duration(seconds: 299));
      positions.add(const Duration(seconds: 301));
      await done;
    });

    test('times out', () async {
      final positions = StreamController<Duration>.broadcast();
      await expectLater(
        awaitFirstAdvance(positions.stream,
            timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      expect(positions.hasListener, isFalse);
      await positions.close();
    });
  });
}
