import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_memory_providers.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/graphql/queries/subtitle_content.graphql.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';
import '../../../test_utils/toast_harness.dart';
import 'player_screen_test_harness.dart';

/// Keeps the media_kit Player and its real streams; only the native decoder
/// and video-output handle are replaced. No mpv/FFI is available in widget tests.
class _Decoder extends PlatformPlayer {
  _Decoder({this.failFirstOpen = false, this.throwFirstOpen = false})
      : super(configuration: const PlayerConfiguration());

  final bool failFirstOpen;
  final bool throwFirstOpen;
  final opened = <Media>[];
  bool disposed = false;

  // VideoController waits for a native output that this test does not render.
  // Keeping the handle unresolved avoids reaching native texture/FFI calls.
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  /// Positions the new source at its [Media.start], as mpv's `start` option
  /// does while it loads the file.
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media);
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: media.start ?? Duration.zero,
      playing: false,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
    if (throwFirstOpen && opened.length == 1) {
      throw StateError('open failed');
    }
    if (failFirstOpen && opened.length == 1) {
      errorController.add('Failed to initialize video decoder');
    }
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async => advance(position);

  void advance(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  void buffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }

  /// Every track the screen asked for, in order.
  final subtitleTracks = <SubtitleTrack>[];

  int get subtitleTrackCalls => subtitleTracks.length;

  /// When set, [setSubtitleTrack] records its track and then does not
  /// return until this completes, so a test can start a switch while a set
  /// is still running.
  Completer<void>? holdSubtitleTrack;

  /// Accepts the switch and emits nothing on `trackController`. That is how
  /// a switch looks to the monitor when media_kit's own track event arrives
  /// after mpv has already started rebuffering.
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleTracks.add(track);
    await holdSubtitleTrack?.future;
  }

  /// `errorController` is `@protected` on `PlatformPlayer`: only reachable
  /// from an instance member of a subclass, which this wrapper is and a test
  /// body is not.
  void emitError(String message) => errorController.add(message);

  /// Same reason as [emitError]: `playingController` is `@protected`.
  bool get hasPlayingListener => playingController.hasListener;

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

/// A small WebVTT body, returned for any `SubtitleContent` request.
const _vtt = 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello\n';

/// A [StubLink] that can hold `SubtitleContent` until [holdSubtitleContent]
/// completes, and every `startStreamingSession` after the first (a switch's)
/// until [holdSwitchStart] completes, so a test can pin how a subtitle
/// fetch and a switch interleave.
class _GatedLink extends StubLink {
  _GatedLink(
    super.handler, {
    this.holdSubtitleContent,
    this.holdSwitchStart,
  });

  final Completer<void>? holdSubtitleContent;
  final Completer<void>? holdSwitchStart;

  /// `SubtitleContent` requests that have reached this link, held or not.
  /// [requests] only records a request once its hold is released.
  int subtitleContentSeen = 0;

  /// `startStreamingSession` requests that have reached this link, held or
  /// not. The first is the initial playback's.
  int sessionStartsSeen = 0;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    if (request.operation.document == documentNodeQuerySubtitleContent) {
      subtitleContentSeen++;
      await holdSubtitleContent?.future;
    } else if (request.variables.containsKey('strategy')) {
      sessionStartsSeen++;
      if (sessionStartsSeen > 1) await holdSwitchStart?.future;
    }
    yield* super.request(request, forward);
  }
}

_GatedLink _server({
  required bool directPlay,
  bool withSubtitle = false,
  Completer<void>? holdSubtitleContent,
  Completer<void>? holdSwitchStart,
  bool failSwitchStart = false,
  String playlistMode = 'WINDOW',
}) {
  var sessionStarts = 0;
  // The pre-play queries now fire concurrently (see `runIsolated`), so an
  // index-keyed dispatch can no longer script them -- dispatch on the
  // operation instead.
  Object handler(Request request, int index) {
    if (request.operation.document == documentNodeQuerySubtitleContent) {
      return {'__typename': 'RootQueryType', 'subtitleContent': _vtt};
    }
    if (isOperation(request, 'MovieDetail')) {
      return movieDetailResponse(
        positionSeconds: 0,
        files: withSubtitle ? [mediaFileWithSubtitle()] : null,
      );
    }
    if (isOperation(request, 'MovieSegments')) return movieSegmentsResponse();
    if (isOperation(request, 'SubtitleTrackSettings')) {
      return subtitleTrackSettingsResponse();
    }
    if (isOperation(request, 'MovieSubtitlePreference')) {
      return subtitlePreferenceResponse();
    }
    if (isOperation(request, 'StreamingCandidates')) {
      return streamingCandidatesResponse(
        directPlay: directPlay,
        duration: 5400,
        height: 1080,
        bitrate: 8000000,
      );
    }
    final variables = request.variables;
    if (variables.containsKey('strategy')) {
      sessionStarts++;
      if (failSwitchStart && sessionStarts > 1) {
        return graphqlErrorResponse('Could not start the encoder');
      }
      return startStreamingSessionResponse(
        sessionId: 'sess-$index',
        startPosition: variables['startPosition'] as int? ?? 0,
        duration: 5400,
        playlistMode: playlistMode,
      );
    }
    if (variables.containsKey('sessionId')) {
      return endStreamingSessionResponse();
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  }

  return _GatedLink(
    handler,
    holdSubtitleContent: holdSubtitleContent,
    holdSwitchStart: holdSwitchStart,
  );
}

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  Player Function() createPlayer, {
  ValueNotifier<bool>? playerVisible,
  int? resumeSeconds,
}) async {
  final player = PlayerScreen(
    mediaId: 'movie-1',
    mediaType: 'movie',
    fileId: 'file-1',
    title: 'The Long Aurora',
    createPlayer: createPlayer,
    resumeSeconds: resumeSeconds,
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: playerVisible == null
          ? player
          : ValueListenableBuilder<bool>(
              valueListenable: playerVisible,
              builder: (_, show, __) => show ? player : const SizedBox.shrink(),
            ),
    ),
  ));
  await tester.pump();
}

/// One monitor tick. `PlaybackMonitor` samples once a second, so each call
/// lets exactly one sample see the decoder's current state.
Future<void> _tick(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

/// End-session requests so far. `_landSwitch` waits for one more: a switch
/// ends the old session only once the new source has advanced.
int _endSessionRequests(StubLink link) =>
    link.requests.where((r) => r.variables.containsKey('sessionId')).length;

/// Seeks to [to], past the transcoded window, which switches sources the
/// same way a quality change or a fallback does, and waits until the switch
/// lands.
Future<void> _switchAndLand(
  WidgetTester tester,
  RemotePlayerBinding binding,
  _Decoder decoder,
  StubLink link, {
  Duration to = const Duration(seconds: 600),
}) async {
  final opensBefore = decoder.opened.length;
  final endsBefore = _endSessionRequests(link);
  final switchFuture = binding.seek(to);
  await pumpUntil(tester, () => decoder.opened.length == opensBefore + 1);
  expect(decoder.opened, hasLength(opensBefore + 1),
      reason: 'the seek must have switched sources');
  await _landSwitch(tester, decoder, link, switchFuture,
      endsBefore: endsBefore);
}

/// Lands a switch whose new source is already open on [decoder].
///
/// Two increasing positions, because `_awaitFirstAdvance` takes the first
/// value it sees as the baseline and waits for one past it. The `runAsync`
/// nudge is the same one "a fault on the incoming source during a switch is
/// forgotten once the switch lands" needs: the switch's mutations go through
/// real `dart:io` HTTP mocking, which plain pumps do not fully resolve.
Future<void> _landSwitch(
  WidgetTester tester,
  _Decoder decoder,
  StubLink link,
  Future<void> switchFuture, {
  required int endsBefore,
}) async {
  var completed = false;
  final tracked = switchFuture.whenComplete(() => completed = true);
  decoder.advance(const Duration(seconds: 1));
  await tester.pump();
  decoder.advance(const Duration(seconds: 2));
  await tester.pump();
  await pumpUntil(tester, () => _endSessionRequests(link) > endsBefore);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpUntil(tester, () => completed);
  await tracked;
}

void main() {
  testWidgets('casting stops verification of the local source', (tester) async {
    final decoder = _Decoder();
    final sessions = StreamController<CastSession?>.broadcast();
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      castSessionStream: sessions.stream,
    );
    // Registered in this order so teardown (LIFO) disposes the container
    // first: that cancels Riverpod's internal subscription to `sessions`,
    // which `castSessionProvider` never detaches from on its own. Closing
    // the controller before that subscriber is gone deadlocks — a broadcast
    // `close()` waits for every listener to be delivered its done event, and
    // nothing here ever cancels the listener except the container going away.
    addTearDown(sessions.close);
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
      expect(find.byType(PlaybackChrome), findsOneWidget);

      sessions.add(const CastSession(
        device: testDevice,
        mediaInfo: CastMediaInfo(
            title: 'The Long Aurora',
            duration: Duration(seconds: 5400),
            position: Duration.zero),
        playbackState: CastPlaybackState.playing,
        connectionState: CastConnectionState.connected,
      ));
      await tester.pump();
      decoder.emitError('Failed to initialize video decoder');
      await tester.pump(const Duration(seconds: 1));
      // Casting stopped verification, so a second open never happens here;
      // this is a bounded wait, not a condition to poll for.
      await tester.pump(const Duration(seconds: 2));

      expect(decoder.opened, hasLength(1));
      final memory = await container.read(playbackMemoryProvider.future);
      expect(memory.failuresFor('test-node', now: DateTime.now()), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a failed open disposes the player and its verification monitor',
      (tester) async {
    final decoder = _Decoder(throwFirstOpen: true);
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await _mount(tester, container, () => Player(platformPlayer: decoder));
    await pumpUntil(tester, () => decoder.disposed);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await pumpUntil(
        tester, () => find.textContaining('open failed').evaluate().isNotEmpty);

    expect(find.textContaining('open failed'), findsOneWidget);
    expect(decoder.disposed, isTrue);
    expect(decoder.hasPlayingListener, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('an error during initial open falls back on the same player',
      (tester) async {
    final decoder = _Decoder(failFirstOpen: true);
    final link = _server(directPlay: true);
    final settings = FakeSettingsService(defaultQuality: 'original');
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: settings,
    );
    addTearDown(container.dispose);
    var playersCreated = 0;

    await mockHttpResponse(() async {
      await _mount(tester, container, () {
        playersCreated++;
        return Player(platformPlayer: decoder);
      });
      await pumpUntil(tester, () => decoder.opened.length == 2);

      expect(decoder.opened, hasLength(2));
      expect(decoder.opened.last.uri, contains('/hls/'));
      final fallbackStart = link.requests
          .lastWhere((r) => r.variables.containsKey('strategy'))
          .variables;
      expect(fallbackStart.containsKey('maxHeight'), isFalse,
          reason: 'Original falls back to a transcode at the source '
              'resolution, not a stepped-down adaptive rung');
      expect(fallbackStart.containsKey('maxBitrate'), isFalse);
      await tester.pump();
      expect(
        tester
            .widget<PlaybackChrome>(find.byType(PlaybackChrome))
            .selectedQualityLabel,
        'Original',
        reason: 'the fallback keeps the viewer on Original, not Auto',
      );
      expect(playersCreated, 1);
      expect(decoder.disposed, isFalse);
      expect(find.byType(PlaybackChrome), findsOneWidget);
      expect(
        find.text(
          "Switched to transcoding: your device can't play this file "
          'directly',
        ),
        findsOneWidget,
      );
      final memory = await container.read(playbackMemoryProvider.future);
      expect(
        memory.failuresFor('test-node', now: DateTime.now()),
        contains(
            const FailureKey(videoCodec: 'avc1.640028', heightBucket: 1080)),
      );
      expect(settings.defaultQuality, 'original',
          reason: 'a fallback never writes the stored default');
      expect(settings.setDefaultQualityCalls, 0);

      decoder.advance(const Duration(seconds: 1));
      await tester.pump();
      decoder.advance(const Duration(seconds: 2));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  // mpv rejects a `seek` until it has loaded the file, and `Player.open`
  // returns before that. A resume sent as a seek after `open` therefore only
  // landed when the source loaded faster than the screen's fixed wait, and
  // otherwise played from zero. The position has to travel with the open.
  testWidgets('a resume opens the source at the saved position',
      (tester) async {
    final decoder = _Decoder();
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await _mount(tester, container, () => Player(platformPlayer: decoder),
        resumeSeconds: 1200);
    await pumpUntil(tester, () => decoder.opened.isNotEmpty);

    expect(decoder.opened.single.start, const Duration(seconds: 1200));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a switch into a full playlist opens it at the current position',
      (tester) async {
    final decoder = _Decoder(failFirstOpen: true);
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true, playlistMode: 'FULL'),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder),
          resumeSeconds: 1200);
      await pumpUntil(tester, () => decoder.opened.length == 2);

      expect(decoder.opened.last.uri, contains('/hls/'));
      expect(decoder.opened.last.start, const Duration(seconds: 1200));

      decoder.advance(const Duration(seconds: 1201));
      await tester.pump();
      decoder.advance(const Duration(seconds: 1202));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a second seek during progress saving cannot replace the first',
      (tester) async {
    final decoder = _Decoder();
    final link = _server(directPlay: false);
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
      expect(find.byType(PlaybackChrome), findsOneWidget);
      decoder.advance(const Duration(seconds: 15));
      await tester.pump();
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;

      var firstCompleted = false;
      final first = binding
          .seek(const Duration(seconds: 600))
          .whenComplete(() => firstCompleted = true);
      final second = binding.seek(const Duration(seconds: 900));
      await pumpUntil(tester, () => decoder.opened.length == 2);

      final starts =
          link.requests.where((r) => r.variables.containsKey('strategy'));
      expect(starts.map((r) => r.variables['startPosition']), [null, 600]);
      expect(decoder.opened, hasLength(2));
      expect(find.byType(PlaybackChrome), findsOneWidget);
      expect(decoder.disposed, isFalse);
      expect(binding.describe(1).positionMs, BigInt.from(600000),
          reason: 'the source has switched to local zero of the 600s window; '
              'remote state and progress must already use that timeline');

      decoder.advance(const Duration(seconds: 1));
      await tester.pump();
      decoder.advance(const Duration(seconds: 2));
      await tester.pump();
      await pumpUntil(tester,
          () => link.requests.any((r) => r.variables['sessionId'] == 'sess-4'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pumpUntil(tester, () => firstCompleted);
      expect(firstCompleted, isTrue,
          reason: 'the replacement must finish after the new source advances; '
              'requests: ${link.requests.map((r) => r.variables)}');
      await first;
      await second;
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a fault on the incoming source during a switch is not deferred to '
      'verification', (tester) async {
    final decoder = _Decoder();
    final link = _server(directPlay: false);
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
      expect(find.byType(PlaybackChrome), findsOneWidget);
      decoder.advance(const Duration(seconds: 15));
      await tester.pump();
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;

      // A WINDOW-mode seek past the transcoded window switches sources.
      // Nothing advances the incoming source's position, so `replaceSource`
      // is still waiting on it (see the previous test's same assumption)
      // when the fault below arrives.
      unawaited(binding.seek(const Duration(seconds: 600)));
      await pumpUntil(tester, () => decoder.opened.length == 2);

      // `_switchSource` stopped verification before this switch even
      // started and only re-arms it once `replaceSource` lands — which it
      // has not, since nothing has advanced the new source's position. A
      // fault here must therefore reach the plain error path, not a policy
      // that would immediately mark itself done and hand back a
      // `FallbackToTranscode` `_fallbackToTranscode` silently drops because
      // a switch is already in flight.
      decoder.emitError('Failed to initialize video decoder');
      await tester.pump();

      expect(find.textContaining('Playback failed'), findsOneWidget);
      expect(find.textContaining('Switched to transcoding'), findsNothing,
          reason: 'a deferred-then-dropped fallback is the bug: no toast '
              'means the fault was not silently swallowed');

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a fault on the incoming source during a switch is forgotten once the '
      'switch lands', (tester) async {
    final decoder = _Decoder();
    final link = _server(directPlay: false);
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
      expect(find.byType(PlaybackChrome), findsOneWidget);
      decoder.advance(const Duration(seconds: 15));
      await tester.pump();
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;

      // Same setup as the previous test: a WINDOW-mode seek switches sources
      // and nothing has advanced the incoming source's position yet, so the
      // fault below surfaces as the plain error page rather than being
      // deferred to a not-yet-armed policy.
      var switchCompleted = false;
      final switchFuture = binding
          .seek(const Duration(seconds: 600))
          .whenComplete(() => switchCompleted = true);
      await pumpUntil(tester, () => decoder.opened.length == 2);

      decoder.emitError('Failed to initialize video decoder');
      await tester.pump();
      expect(find.textContaining('Playback failed'), findsOneWidget);

      // The incoming source was never actually broken: it goes on to
      // advance normally, and the switch lands. Two increasing positions are
      // needed because `_awaitFirstAdvance` treats the first value it sees
      // as the baseline and waits for one past it. The same
      // `runAsync`-then-`pumpUntil(switchCompleted)` sequence as "a second
      // seek during progress saving cannot replace the first" above: the
      // switch's mutations go through real `dart:io` HTTP mocking, which
      // does not fully resolve under plain `pump()`s alone.
      decoder.advance(const Duration(seconds: 1));
      await tester.pump();
      decoder.advance(const Duration(seconds: 2));
      await tester.pump();
      await pumpUntil(tester,
          () => link.requests.any((r) => r.variables['sessionId'] == 'sess-4'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await pumpUntil(tester, () => switchCompleted);
      await switchFuture;

      expect(find.textContaining('Playback failed'), findsNothing,
          reason: 'the switch landed after the fault; the error page must '
              'not be left over a working video');
      expect(find.byType(PlaybackChrome), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('under Auto, two stalls replace a direct play source',
      (tester) async {
    final decoder = _Decoder();
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(tester, () => decoder.state.playing, maxTries: 500);

      await _tick(tester); // playback has run once
      decoder.buffering(true);
      await _tick(tester); // stall 1
      decoder.buffering(false);
      await _tick(tester);
      decoder.buffering(true);
      await _tick(tester); // stall 2

      await pumpUntil(tester, () => decoder.opened.length == 2);
      expect(decoder.opened, hasLength(2));
      expect(decoder.opened.last.uri, contains('/hls/'));
      expect(
        find.text('Switched to transcoding for your connection'),
        findsOneWidget,
      );

      decoder.buffering(false);
      decoder.advance(const Duration(seconds: 1));
      await tester.pump();
      decoder.advance(const Duration(seconds: 2));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('under Original, stalls never replace a direct play source',
      (tester) async {
    final decoder = _Decoder();
    final link = _server(directPlay: true);
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: 'original'),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(tester, () => decoder.state.playing, maxTries: 500);

      await _tick(tester); // playback has run once
      decoder.buffering(true);
      await _tick(tester); // stall 1
      decoder.buffering(false);
      await _tick(tester);
      decoder.buffering(true);
      await _tick(tester); // stall 2
      decoder.buffering(false);
      // Bounded, not polled: nothing should happen, and a fallback would
      // land well inside this window (the Auto test above reaches its second
      // open within pumpUntil's 2 s budget).
      await tester.pump(const Duration(seconds: 3));

      expect(decoder.opened, hasLength(1));
      expect(link.requests.where((r) => r.variables.containsKey('strategy')),
          isEmpty);
      expect(find.textContaining('Switched to transcoding'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a rebuffer right after a subtitle switch is not a stall, however late '
      'media_kit reports the switch', (tester) async {
    final decoder = _Decoder();
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(tester, () => decoder.state.playing, maxTries: 500);
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;

      await _tick(tester); // playback has run once
      decoder.buffering(true);
      await _tick(tester); // stall 1
      decoder.buffering(false);
      await _tick(tester);

      // `_Decoder.setSubtitleTrack` emits no track event, so only the
      // screen's own note can explain the rebuffer that follows. Auto, so a
      // second counted stall would fall back.
      final callsBefore = decoder.subtitleTrackCalls;
      await binding.selectTrack(TrackKind.subtitle, null);
      expect(decoder.subtitleTrackCalls, callsBefore + 1);
      decoder.buffering(true);
      await _tick(tester); // would be stall 2 without the note
      decoder.buffering(false);
      await tester.pump(const Duration(seconds: 3));

      expect(decoder.opened, hasLength(1));
      expect(find.textContaining('Switched to transcoding'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'picking Original over a direct play Auto source stops stalls replacing '
      'it, though nothing reopens', (tester) async {
    final decoder = _Decoder();
    final container = buildPlayerScreenContainer(
      link: _server(directPlay: true),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, container, () => Player(platformPlayer: decoder));
      await pumpUntil(tester, () => decoder.state.playing, maxTries: 500);

      // Auto and Original both direct play this file, so the pick changes
      // the choice without reopening, and the policy already watching the
      // source is the one that has to change its mind.
      final chrome = tester.widget<PlaybackChrome>(find.byType(PlaybackChrome));
      chrome.onQualityTap!();
      const originalRow = Key('quality-rung-Original');
      await pumpUntil(
          tester, () => find.byKey(originalRow).evaluate().isNotEmpty);
      await tester.tap(find.byKey(originalRow));
      await pumpUntil(
        tester,
        () =>
            tester
                .widget<PlaybackChrome>(find.byType(PlaybackChrome))
                .selectedQualityLabel ==
            'Original',
      );

      await _tick(tester); // playback has run once
      decoder.buffering(true);
      await _tick(tester); // stall 1
      decoder.buffering(false);
      await _tick(tester);
      decoder.buffering(true);
      await _tick(tester); // stall 2
      decoder.buffering(false);
      await tester.pump(const Duration(seconds: 3));

      expect(decoder.opened, hasLength(1));
      expect(find.textContaining('Switched to transcoding'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  group('the subtitle choice across a source switch', () {
    Future<(RemotePlayerBinding, _Decoder, _GatedLink)> mountStreaming(
      WidgetTester tester, {
      bool withSubtitle = false,
      Completer<void>? holdSubtitleContent,
      Completer<void>? holdSwitchStart,
      bool failSwitchStart = false,
      ValueNotifier<bool>? playerVisible,
    }) async {
      final decoder = _Decoder();
      final link = _server(
        directPlay: false,
        withSubtitle: withSubtitle,
        holdSubtitleContent: holdSubtitleContent,
        holdSwitchStart: holdSwitchStart,
        failSwitchStart: failSwitchStart,
      );
      final container = buildPlayerScreenContainer(
        link: link,
        connectionState: conn.ConnectionState.direct(),
        castManager: CapturingCastSessionManager(),
        proxyService: TrackingLocalProxyService(),
      );
      addTearDown(container.dispose);

      await _mount(
        tester,
        container,
        () => Player(platformPlayer: decoder),
        playerVisible: playerVisible,
      );
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
      decoder.advance(const Duration(seconds: 15));
      await tester.pump();
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;
      return (binding, decoder, link);
    }

    int contentRequestCount(StubLink link) => link.requests
        .where((r) => r.operation.document == documentNodeQuerySubtitleContent)
        .length;

    testWidgets('a picked subtitle is shown again once the switch lands',
        (tester) async {
      await mockHttpResponse(() async {
        final (binding, decoder, link) =
            await mountStreaming(tester, withSubtitle: true);

        unawaited(binding.selectTrack(TrackKind.subtitle, '3'));
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);
        expect(decoder.subtitleTracks, hasLength(1));
        final picked = decoder.subtitleTracks.single;
        expect(picked.data, isTrue);
        expect(binding.describe(0).selectedSubtitle, '3');

        await _switchAndLand(tester, binding, decoder, link);

        // mpv drops a `sub-add`ed track when it opens the new file, so the
        // same body has to be added again, and the screen has to say so.
        await pumpUntil(tester, () => decoder.subtitleTracks.length == 2);
        expect(decoder.subtitleTracks, hasLength(2));
        expect(decoder.subtitleTracks.last, picked);
        expect(binding.describe(0).selectedSubtitle, '3');
        expect(contentRequestCount(link), 1,
            reason: 'the body fetched for the pick is reused, not fetched '
                'again for the new source');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets('an Off the viewer chose is applied again after the switch',
        (tester) async {
      await mockHttpResponse(() async {
        final (binding, decoder, link) = await mountStreaming(tester);

        unawaited(binding.selectTrack(TrackKind.subtitle, null));
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);
        expect(decoder.subtitleTracks.single, SubtitleTrack.no());

        await _switchAndLand(tester, binding, decoder, link);

        // Explicitly, so a subtitle mpv would pick on its own for the new
        // file cannot appear over the viewer's Off.
        await pumpUntil(tester, () => decoder.subtitleTracks.length == 2);
        expect(decoder.subtitleTracks, hasLength(2));
        expect(decoder.subtitleTracks.last, SubtitleTrack.no());
        expect(binding.describe(0).selectedSubtitle, isNull);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets(
        'the loading toast closes after the screen unmounts during the fetch',
        (tester) async {
      await mockHttpResponse(() async {
        final hold = Completer<void>();
        addTearDown(() {
          if (!hold.isCompleted) hold.complete();
        });
        final visible = ValueNotifier(true);
        addTearDown(visible.dispose);
        final (binding, decoder, link) = await mountStreaming(
          tester,
          withSubtitle: true,
          holdSubtitleContent: hold,
          playerVisible: visible,
        );

        unawaited(binding.selectTrack(TrackKind.subtitle, '3'));
        await pumpUntil(tester,
            () => find.text('Loading subtitle...').evaluate().isNotEmpty);
        expect(find.text('Loading subtitle...'), findsOneWidget);

        visible.value = false;
        await tester.pump();
        expect(find.byType(PlayerScreen), findsNothing);
        expect(find.text('Loading subtitle...'), findsOneWidget,
            reason: 'the layer outlives the player; the toast stays up '
                'until the fetch returns and the handle closes');

        hold.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('Loading subtitle...'), findsNothing,
            reason: 'ToastHandle.close does not need the player screen to '
                'still be mounted');
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets('a viewer who never chose keeps mpv\'s own defaults',
        (tester) async {
      await mockHttpResponse(() async {
        final (binding, decoder, link) =
            await mountStreaming(tester, withSubtitle: true);

        await _switchAndLand(tester, binding, decoder, link);
        await tester.pump(const Duration(seconds: 1));

        // Forcing Off here would hide a forced or default track mpv shows
        // on a fresh open at Original.
        expect(decoder.subtitleTracks, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });
    testWidgets(
        'a restore still fetching when a second switch starts never reaches '
        'the outgoing source', (tester) async {
      await mockHttpResponse(() async {
        final body = Completer<void>();
        addTearDown(() {
          if (!body.isCompleted) body.complete();
        });
        final (binding, decoder, link) = await mountStreaming(
          tester,
          withSubtitle: true,
          holdSubtitleContent: body,
        );

        // The pick's body is held, so switch 1 lands with it still fetching
        // and restore 1 has to wait for a body too.
        unawaited(binding.selectTrack(TrackKind.subtitle, '3'));
        await pumpUntil(tester, () => link.subtitleContentSeen == 1);
        await _switchAndLand(tester, binding, decoder, link);
        expect(decoder.subtitleTracks, isEmpty);

        final opensBefore = decoder.opened.length;
        final endsBefore = _endSessionRequests(link);
        final second = binding.seek(const Duration(seconds: 1800));
        await pumpUntil(tester, () => decoder.opened.length == opensBefore + 1);
        expect(decoder.opened, hasLength(opensBefore + 1),
            reason: 'the second seek must have switched sources');

        // Switch 2 has opened its file and not landed: the body arriving
        // now must not reach the player.
        body.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(decoder.subtitleTracks, isEmpty,
            reason: 'restore 1 waits for switch 2 instead of calling '
                'setSubtitleTrack while the file is being replaced');

        await _landSwitch(tester, decoder, link, second,
            endsBefore: endsBefore);
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);
        await tester.pump(const Duration(milliseconds: 250));

        expect(decoder.subtitleTracks, hasLength(1),
            reason: 'restore 1 backs off once switch 2 lands, and restore 2 '
                'applies the choice once');
        expect(decoder.subtitleTracks.single.data, isTrue);
        expect(binding.describe(0).selectedSubtitle, '3');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets(
        'a subtitle call already running holds the switch until it returns',
        (tester) async {
      await mockHttpResponse(() async {
        final (binding, decoder, link) = await mountStreaming(tester);
        final set = Completer<void>();
        addTearDown(() {
          if (!set.isCompleted) set.complete();
        });
        decoder.holdSubtitleTrack = set;

        unawaited(binding.selectTrack(TrackKind.subtitle, null));
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);
        expect(decoder.subtitleTracks.single, SubtitleTrack.no());

        final opensBefore = decoder.opened.length;
        final endsBefore = _endSessionRequests(link);
        final switchFuture = binding.seek(const Duration(seconds: 600));
        await pumpUntil(tester, () => decoder.opened.length > opensBefore);
        expect(decoder.opened, hasLength(opensBefore),
            reason: 'the switch must not replace the file while '
                'setSubtitleTrack is still running on it');

        set.complete();
        await pumpUntil(tester, () => decoder.opened.length > opensBefore);
        expect(decoder.opened, hasLength(opensBefore + 1));

        await _landSwitch(tester, decoder, link, switchFuture,
            endsBefore: endsBefore);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets(
        'a pick waiting on a switch that fails still applies to the source '
        'that stayed', (tester) async {
      await mockHttpResponse(() async {
        final body = Completer<void>();
        final switchStart = Completer<void>();
        addTearDown(() {
          if (!body.isCompleted) body.complete();
          if (!switchStart.isCompleted) switchStart.complete();
        });
        final (binding, decoder, link) = await mountStreaming(
          tester,
          withSubtitle: true,
          holdSubtitleContent: body,
          holdSwitchStart: switchStart,
          failSwitchStart: true,
        );

        unawaited(binding.selectTrack(TrackKind.subtitle, '3'));
        await pumpUntil(tester, () => link.subtitleContentSeen == 1);

        final opensBefore = decoder.opened.length;
        var switchDone = false;
        unawaited(binding
            .seek(const Duration(seconds: 600))
            .whenComplete(() => switchDone = true));
        await pumpUntil(tester, () => link.sessionStartsSeen == 2);

        // The body arrives while the switch waits on its session start.
        body.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(decoder.subtitleTracks, isEmpty,
            reason: 'the pick waits at the gate while the switch is in '
                'flight');

        switchStart.complete();
        await pumpUntil(tester, () => switchDone);
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);

        expect(decoder.opened, hasLength(opensBefore),
            reason: 'the failed switch never attached a new source');
        expect(decoder.subtitleTracks, hasLength(1));
        expect(decoder.subtitleTracks.single.data, isTrue);
        expect(binding.describe(0).selectedSubtitle, '3',
            reason: 'a failed switch bumps no generation, so the pick it '
                'held back lands on the source still playing');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });

    testWidgets(
        'a restore that starts while the pick\'s body is still fetching '
        'shares that fetch', (tester) async {
      await mockHttpResponse(() async {
        final body = Completer<void>();
        addTearDown(() {
          if (!body.isCompleted) body.complete();
        });
        final (binding, decoder, link) = await mountStreaming(
          tester,
          withSubtitle: true,
          holdSubtitleContent: body,
        );

        unawaited(binding.selectTrack(TrackKind.subtitle, '3'));
        await pumpUntil(tester, () => link.subtitleContentSeen == 1);
        await _switchAndLand(tester, binding, decoder, link);
        // Room for the restore to reach the link, if it asks on its own.
        await pumpUntil(tester, () => link.subtitleContentSeen > 1,
            maxTries: 10);

        body.complete();
        await pumpUntil(tester, () => decoder.subtitleTracks.isNotEmpty);
        await tester.pump(const Duration(milliseconds: 250));

        expect(link.subtitleContentSeen, 1,
            reason: 'the restore joins the fetch the pick started instead of '
                'asking the server to extract the same body again');
        expect(decoder.subtitleTracks, hasLength(1));
        expect(binding.describe(0).selectedSubtitle, '3');

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
    });
  });
}
