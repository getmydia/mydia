import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_memory_providers.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';
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

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
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

StubLink _server({required bool directPlay}) => StubLink((request, index) {
      if (index == 0) return movieDetailResponse(positionSeconds: 0);
      if (index == 1) return movieSegmentsResponse();
      if (index == 2) return subtitleTrackSettingsResponse();
      if (index == 3) {
        return streamingCandidatesResponse(
          directPlay: directPlay,
          duration: 5400,
          height: 1080,
          bitrate: 8000000,
        );
      }
      final variables = request.variables;
      if (variables.containsKey('strategy')) {
        return startStreamingSessionResponse(
          sessionId: 'sess-$index',
          startPosition: variables['startPosition'] as int? ?? 0,
          duration: 5400,
        );
      }
      if (variables.containsKey('sessionId')) {
        return endStreamingSessionResponse();
      }
      return <String, dynamic>{
        '__typename': 'RootMutationType',
        'updateMovieProgress': null,
      };
    });

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  Player Function() createPlayer,
) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: PlayerScreen(
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'Arrival',
        createPlayer: createPlayer,
      ),
    ),
  ));
  await tester.pump();
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
            title: 'Arrival',
            duration: Duration(seconds: 5400),
            position: Duration.zero),
        playbackState: CastPlaybackState.playing,
        connectionState: CastConnectionState.connected,
      ));
      await tester.pump();
      decoder.emitError('Failed to initialize video decoder');
      await tester.pump(const Duration(seconds: 1));
      await pumpUntil(tester, () => decoder.opened.length == 2);

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
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
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
      expect(playersCreated, 1);
      expect(decoder.disposed, isFalse);
      expect(find.byType(PlaybackChrome), findsOneWidget);
      expect(
        find.text('Switched to transcoding: your device dropped frames'),
        findsOneWidget,
      );
      final memory = await container.read(playbackMemoryProvider.future);
      expect(
        memory.failuresFor('test-node', now: DateTime.now()),
        contains(
            const FailureKey(videoCodec: 'avc1.640028', heightBucket: 1080)),
      );

      decoder.advance(const Duration(seconds: 1));
      await tester.pump();
      decoder.advance(const Duration(seconds: 2));
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
          reason: 'a deferred-then-dropped fallback is the bug: no snackbar '
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
}
