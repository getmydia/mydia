import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/server_features.dart';
import 'package:player/core/playback/stream_urls.dart';
import 'package:player/domain/models/quality_rung.dart';

import '../../presentation/screens/player/player_screen_test_harness.dart';
import '../../test_utils/stub_graphql_client.dart';

const _endOk = {'__typename': 'RootMutationType', 'endStreamingSession': true};

/// Routes by variables, since `operationName` is null under StubLink: a
/// request carrying `sessionId` is EndStreamingSession, anything else is a
/// StartStreamingSession variant.
StubLink _link({required List<Object> starts, Object end = _endOk}) {
  var next = 0;
  return StubLink((request, _) {
    if (request.variables.containsKey('sessionId')) return end;
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
}

Future<({int status, String body})> _readyProbe(
        String url, Map<String, String>? headers) async =>
    (status: 200, body: 'a.ts\nb.ts\nc.ts\n');

PlaybackController _controller(
  StubLink link, {
  bool relayed = false,
  ServerFeatures? features,
  PlaylistProbe probe = _readyProbe,
  Duration firstAdvanceTimeout = const Duration(seconds: 60),
}) =>
    PlaybackController(
      client: () => stubClient(link),
      urls: _Urls(),
      features: features ?? ServerFeatures(),
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

void main() {
  group('open', () {
    test('direct play resolves a URL and starts no session', () async {
      final link = _link(starts: const []);
      final controller = _controller(link);
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
      expect(link.requests, isEmpty);
    });

    test('a copy session asks for HLS_COPY, FULL, no caps', () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 's1', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      final vars = link.requests.single.variables;
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
      final link = _link(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', startPosition: 598, duration: 2400),
      ]);
      final controller = _controller(link);
      final source = await controller.open(_transcode480,
          fileId: 'file-1', startAt: const Duration(seconds: 600));
      expect(link.requests.single.variables['startPosition'], 600);
      expect(link.requests.single.variables['strategy'], 'TRANSCODE');
      expect(source.fullPlaylist, isFalse);
      expect(source.seekOnOpen, isFalse);
      expect(source.timeline.startOffset, const Duration(seconds: 598));
      expect(source.timeline.totalDuration, const Duration(seconds: 2400));
    });

    test('a fixed rung sends its caps; a relay tightens them', () async {
      final link = _link(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', maxBitrate: 1500, maxHeight: 480),
      ]);
      final controller = _controller(link, relayed: true);
      final source = await controller.open(_transcode480,
          fileId: 'file-1', startAt: Duration.zero);
      expect(link.requests.single.variables['maxBitrate'], 1500);
      expect(link.requests.single.variables['maxHeight'], 480);
      expect(source.effectiveRung?.label, '480p');
    });

    test('a relay caps an Original copy request to 3000 kbps and 720p',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(
            sessionId: 's1', maxBitrate: 3000, maxHeight: 720),
      ]);
      final controller = _controller(link, relayed: true);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      expect(link.requests.single.variables['maxBitrate'], 3000);
      expect(link.requests.single.variables['maxHeight'], 720);
      expect(source.effectiveRung?.label, '720p');
    });

    test('an old server without maxHeight is retried with the legacy document',
        () async {
      final link = _link(starts: [
        graphqlErrorResponse('Unknown argument "maxHeight" on field '
            '"startStreamingSession" of type "RootMutationType".'),
        legacyStartStreamingSessionResponse(sessionId: 's1'),
      ]);
      final features = ServerFeatures();
      final controller = _controller(link, features: features);
      final source = await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero);
      expect(link.requests, hasLength(2));
      expect(link.requests.last.variables.containsKey('maxHeight'), isFalse);
      expect(link.requests.last.variables.containsKey('playlistMode'), isFalse);
      expect(features.heightCap, isFalse);
      expect(source.sessionId, 's1');
      expect(source.fullPlaylist, isFalse);
      // The legacy document echoes no caps, so nothing is claimed.
      expect(source.effectiveRung, isNull);

      // The next open skips straight to the legacy document.
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      expect(link.requests, hasLength(3));
      expect(link.requests.last.variables.containsKey('maxHeight'), isFalse);
    });

    test('a genuine mutation failure is thrown, not retried', () async {
      final link =
          _link(starts: [graphqlErrorResponse('Media file not found')]);
      final controller = _controller(link);
      await expectLater(
        controller.open(_copy, fileId: 'file-1', startAt: Duration.zero),
        throwsA(isA<Exception>()),
      );
      expect(link.requests, hasLength(1));
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

      final link =
          _link(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      final controller = _controller(link, probe: probe);
      final messages = <String>[];
      await controller.open(_copy,
          fileId: 'file-1', startAt: Duration.zero, onProgress: messages.add);
      expect(polls, 3);
      expect(messages, contains('Preparing stream... 33%'));
    });

    test('a playlist that never becomes ready ends its session', () async {
      final link =
          _link(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      var polls = 0;
      final delays = <Duration>[];
      final controller = PlaybackController(
        client: () => stubClient(link),
        urls: _Urls(),
        features: ServerFeatures(),
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
      expect(link.requests.last.variables['sessionId'], 's1');
    });

    for (final message in [
      'Cannot query field "maxHeight" on type "StreamingSessionResult".',
      'Unknown argument "playlistMode" on field "startStreamingSession".',
      'Cannot query field "playlistMode" on type "StreamingSessionResult".',
    ]) {
      test('uses the legacy document for $message', () async {
        final link = _link(starts: [
          graphqlErrorResponse(message),
          legacyStartStreamingSessionResponse(
            sessionId: 'legacy',
            startPosition: 298,
            duration: 2400,
          ),
        ]);
        final features = ServerFeatures();
        final source = await _controller(link, features: features).open(
          _transcode480,
          fileId: 'file-1',
          startAt: const Duration(seconds: 300),
        );
        expect(link.requests, hasLength(2));
        expect(link.requests.last.variables, {
          'fileId': 'file-1',
          'strategy': 'TRANSCODE',
          'maxBitrate': 1500,
          'startPosition': 300,
        });
        expect(source.timeline.startOffset, const Duration(seconds: 298));
        expect(source.timeline.totalDuration, const Duration(seconds: 2400));
        expect(source.seekOnOpen, isFalse);
        expect(source.effectiveRung, isNull);
        expect(features.heightCap, isFalse);
      });
    }

    for (final failure in <Object>[
      graphqlErrorResponse('Unauthorized to set maxHeight or playlistMode'),
      Exception('Unknown argument "maxHeight" in a transport failure'),
    ]) {
      test(
          'does not classify resolver or transport errors as schema skew: '
          '$failure', () async {
        final link = _link(starts: [failure]);
        final features = ServerFeatures();
        await expectLater(
          _controller(link, features: features).open(
            _copy,
            fileId: 'file-1',
            startAt: Duration.zero,
          ),
          throwsA(isA<Exception>()),
        );
        expect(link.requests, hasLength(1));
        expect(features.heightCap, isTrue);
      });
    }

    test('FULL ignores the echoed offset and preserves the known runtime',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(
          playlistMode: 'FULL',
          startPosition: 598,
          duration: 1800,
        )
      ]);
      final source = await _controller(link).open(
        _copy,
        fileId: 'file-1',
        startAt: const Duration(seconds: 600),
        totalDuration: const Duration(seconds: 2400),
      );
      expect(source.timeline.startOffset, Duration.zero);
      expect(source.timeline.totalDuration, const Duration(seconds: 2400));
      expect(source.seekOnOpen, isTrue);
    });
  });

  group('replaceSource', () {
    test('a failed playlist ends the new session and keeps the old', () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'old'),
        startStreamingSessionResponse(sessionId: 'new'),
      ]);
      final controller = _controller(link, probe: (url, headers) async {
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
      expect(link.requests.last.variables['sessionId'], 'new');
    });

    test('waits the full 60 seconds before timing out a switch', () {
      fakeAsync((clock) {
        final link = _link(starts: [
          startStreamingSessionResponse(sessionId: 'old'),
          startStreamingSessionResponse(sessionId: 'new'),
        ]);
        final controller = _controller(link);
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
        expect(link.requests, hasLength(2));
        expect(failure, isNull);
        clock.elapse(const Duration(seconds: 1));
        clock.flushMicrotasks();
        expect(failure, isA<TimeoutException>());
        expect(controller.switching, isFalse);
        expect(controller.sessionId, 'old');
        expect(link.requests.last.variables['sessionId'], 'new');
        expect(positions.hasListener, isFalse);
        unawaited(positions.close());
        clock.flushMicrotasks();
      });
    });

    test('switching to direct play ends the old session after advancement',
        () async {
      final link =
          _link(starts: [startStreamingSessionResponse(sessionId: 'old')]);
      final controller = _controller(link);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final source = await controller.replaceSource(
        _direct,
        fileId: 'file-1',
        realPosition: const Duration(seconds: 300),
        attach: (source) async {
          expect(source.seekOnOpen, isTrue);
          expect(link.requests, hasLength(1));
          return Stream.fromIterable(const [
            Duration(seconds: 300),
            Duration(seconds: 301),
          ]);
        },
      );
      expect(source.url, 'direct://file-1');
      expect(controller.sessionId, isNull);
      expect(link.requests.last.variables['sessionId'], 'old');
    });
    test('starts the new session, attaches, waits, then ends the old one',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);

      final listening = Completer<void>();
      final positions = StreamController<Duration>.broadcast(
        onListen: listening.complete,
      );
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
      expect(link.requests.map((r) => r.variables['sessionId']), [null, null]);

      await listening.future;
      positions.add(const Duration(seconds: 300));
      positions.add(const Duration(seconds: 301));
      final source = await switched;

      expect(source.sessionId, 'new');
      expect(controller.sessionId, 'new');
      expect(controller.switching, isFalse);
      expect(link.requests.last.variables['sessionId'], 'old');
      expect(link.requests.map((r) => r.variables['fileId']),
          ['file-1', 'file-1', null]);
    });

    test('a switch from direct play ends nothing and records the session',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link);
      await controller.open(_direct, fileId: 'file-1', startAt: Duration.zero);
      await controller.replaceSource(
        _transcode480,
        fileId: 'file-1',
        realPosition: const Duration(seconds: 10),
        attach: (_) async => Stream.fromIterable(
            const [Duration(seconds: 10), Duration(seconds: 11)]),
      );
      expect(controller.sessionId, 'new');
      expect(link.requests.map((r) => r.variables['sessionId']), [null]);
    });

    test('an attach that fails ends the new session and keeps the old',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link);
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
      expect(link.requests.last.variables['sessionId'], 'new');
    });

    test('a source that never advances times out and keeps the old session',
        () async {
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link,
          firstAdvanceTimeout: const Duration(milliseconds: 20));
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final stuck = StreamController<Duration>.broadcast();
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
      final link = _link(starts: [
        startStreamingSessionResponse(sessionId: 'old', playlistMode: 'FULL'),
        startStreamingSessionResponse(sessionId: 'new', playlistMode: 'FULL'),
      ]);
      final controller = _controller(link);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      final positions = StreamController<Duration>.broadcast();
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
    test('resolves the current client and tolerates a failed end', () async {
      final starts =
          _link(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      final ends =
          _link(starts: [], end: graphqlErrorResponse('Already ended'));
      GraphQLClient? client = stubClient(starts);
      final controller = PlaybackController(
        client: () => client,
        urls: _Urls(),
        features: ServerFeatures(),
        relayed: false,
        probe: _readyProbe,
        wait: (_) async {},
      );
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      client = stubClient(ends);
      await controller.endSession();
      expect(controller.sessionId, isNull);
      expect(starts.requests, hasLength(1));
      expect(ends.requests.single.variables['sessionId'], 's1');
    });

    test('clears a live session when the client has disappeared', () async {
      final link =
          _link(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      GraphQLClient? client = stubClient(link);
      final controller = PlaybackController(
        client: () => client,
        urls: _Urls(),
        features: ServerFeatures(),
        relayed: false,
        probe: _readyProbe,
        wait: (_) async {},
      );
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      client = null;
      await controller.endSession();
      await controller.endSession();
      expect(controller.sessionId, isNull);
      expect(link.requests, hasLength(1));
    });
    test('ends the current session once, then is a no-op', () async {
      final link =
          _link(starts: [startStreamingSessionResponse(sessionId: 's1')]);
      final controller = _controller(link);
      await controller.open(_copy, fileId: 'file-1', startAt: Duration.zero);
      await controller.endSession();
      await controller.endSession();
      expect(controller.sessionId, isNull);
      expect(link.requests.where((r) => r.variables.containsKey('sessionId')),
          hasLength(1));
    });

    test('a missing client is logged, never thrown', () async {
      final controller = PlaybackController(
        client: () => null,
        urls: _Urls(),
        features: ServerFeatures(),
        relayed: false,
        probe: _readyProbe,
        wait: (_) async {},
      );
      await expectLater(
        controller.open(_copy, fileId: 'file-1', startAt: Duration.zero),
        throwsA(isA<StateError>()),
      );
      await controller.endSession();
    });
  });

  group('awaitFirstAdvance', () {
    test('completes on the first position past the first one seen', () async {
      final positions = StreamController<Duration>.broadcast();
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
