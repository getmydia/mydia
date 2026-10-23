import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/media_proxy_factory.dart';
import 'package:player/core/remote/remote_target_controller.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/player_screen_views.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/mydia_test_source.dart';
import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import '../../../test_utils/toast_harness.dart';
import 'player_screen_test_harness.dart';

/// Keeps the media_kit Player and its real streams; only the native decoder
/// and video-output handle are replaced. No mpv/FFI is available in widget
/// tests.
class _Decoder extends PlatformPlayer {
  _Decoder() : super(configuration: const PlayerConfiguration());

  final opened = <Media>[];
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

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
    state = state.copyWith(tracks: probedTracks());
    tracksController.add(state.tracks);
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
  Future<void> seek(Duration position) async => advanceTo(position);

  void advanceTo(Duration position) {
    state = state.copyWith(position: position, playing: true);
    positionController.add(position);
  }

  /// What mpv does once it has run out of connection retries: report the
  /// open failure and unload the file.
  void loseSource() {
    errorController
        .add('Failed to open http://127.0.0.1:12345/direct/f/stream.');
    state = state.copyWith(position: Duration.zero, duration: Duration.zero);
    positionController.add(Duration.zero);
    durationController.add(Duration.zero);
  }
}

/// Holds every `startStreamingSession` after the first, a switch's, until
/// [holdSwitchStart] completes, so a test can lose the source mid-switch.
class _GatedLink extends ScriptedMydiaTransport {
  _GatedLink(super.handler, {this.holdSwitchStart});

  final Completer<void>? holdSwitchStart;
  int _sessionStarts = 0;

  @override
  Future<Map<String, dynamic>> send(
    String query,
    Map<String, dynamic> variables, {
    String? token,
    String? deviceProfile,
    Duration? timeout,
  }) async {
    if (variables.containsKey('strategy') && ++_sessionStarts > 1) {
      await holdSwitchStart?.future;
    }
    return super.send(query, variables,
        token: token, deviceProfile: deviceProfile, timeout: timeout);
  }
}

ScriptedMydiaTransport _server({
  bool directPlay = true,
  Completer<void>? holdSwitchStart,
}) {
  Object handler(ScriptedRequest request, int index) {
    if (request.variables.containsKey('strategy')) {
      return startStreamingSessionResponse(
        sessionId: 'sess-$index',
        startPosition: request.variables['startPosition'] as int? ?? 0,
        duration: 5400,
        playlistMode: 'WINDOW',
      );
    }
    if (request.variables.containsKey('sessionId')) {
      return endStreamingSessionResponse();
    }
    switch (request.operation) {
      case 'MovieDetail':
        return movieDetailResponse(positionSeconds: 0);
      case 'MovieSegments':
        return movieSegmentsResponse();
      case 'SubtitleTrackSettings':
        return subtitleTrackSettingsResponse();
      case 'MovieSubtitlePreference':
        return subtitlePreferenceResponse();
      case 'StreamingCandidates':
        return streamingCandidatesResponse(
          directPlay: directPlay,
          duration: 5400,
          height: 1080,
          bitrate: 8000000,
        );
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  }

  return _GatedLink(handler, holdSwitchStart: holdSwitchStart);
}

Future<void> _mount(
  WidgetTester tester,
  ProviderContainer container,
  _Decoder decoder,
) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: 'movie-1',
        mediaType: 'movie',
        fileId: 'file-1',
        title: 'The Long Aurora',
        session: MydiaPlaybackSession(
          source: container.read(mediaSourceProvider(testMydiaSourceId))
              as MydiaSource,
          item: const ItemRef(
            sourceId: testMydiaSourceId,
            kind: ItemKind.movie,
            externalId: 'movie-1',
          ),
          fileId: 'file-1',
          proxy: () => container.read(mediaProxyProvider),
        ),
        createPlayer: () => Player(platformPlayer: decoder),
      ),
    ),
  ));
  await tester.pump();
}

/// Mounts a direct-play screen and plays it to 75s, so playback has
/// advanced and 75s is the last good position.
Future<void> _playTo75(WidgetTester tester, _Decoder decoder) async {
  await pumpUntil(
      tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
  decoder.advanceTo(const Duration(seconds: 60));
  await tester.pump();
  decoder.advanceTo(const Duration(seconds: 75));
  await tester.pump();
}

/// Lets a reopen that is already under way land: the new source has to
/// advance before the switch completes.
Future<void> _landReopen(
    WidgetTester tester, _Decoder decoder, int opens) async {
  await pumpUntil(tester, () => decoder.opened.length == opens);
  decoder.advanceTo(const Duration(seconds: 76));
  await tester.pump();
  decoder.advanceTo(const Duration(seconds: 77));
  await tester.pump();
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void main() {
  late _Decoder decoder;
  late TrackingLocalProxyService proxy;
  late ProviderContainer container;

  setUp(() {
    decoder = _Decoder();
    proxy = TrackingLocalProxyService();
    container = buildPlayerScreenContainer(
      server: _server(),
      connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxy,
    );
    addTearDown(container.dispose);
  });

  testWidgets('a lost source reopens once at the last good position',
      (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await _playTo75(tester, decoder);
      expect(decoder.opened, hasLength(1));
      final healsBefore = proxy.healCalls;

      decoder.loseSource();
      await tester.pump();
      await _landReopen(tester, decoder, 2);

      expect(decoder.opened, hasLength(2));
      expect(decoder.opened.last.start, const Duration(seconds: 75));
      expect(proxy.healCalls, greaterThan(healsBefore));
      expect(find.byType(PlayerErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a second loss within the window shows the error page',
      (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await _playTo75(tester, decoder);

      decoder.loseSource();
      await tester.pump();
      await _landReopen(tester, decoder, 2);
      expect(find.byType(PlayerErrorView), findsNothing);

      decoder.loseSource();
      await tester.pump();
      await tester.pump();

      expect(find.byType(PlayerErrorView), findsOneWidget);
      expect(decoder.opened, hasLength(2));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a heal to a new port reopens the stream', (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await _playTo75(tester, decoder);

      proxy.healEvents.add(ProxyHeal.reboundNewPort);
      await tester.pump();
      await _landReopen(tester, decoder, 2);

      expect(decoder.opened, hasLength(2));
      expect(decoder.opened.last.start, const Duration(seconds: 75));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a heal to the same port leaves playback alone', (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await _playTo75(tester, decoder);

      proxy.healEvents.add(ProxyHeal.reboundSamePort);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(decoder.opened, hasLength(1));
      expect(find.byType(PlayerErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a heal to a new port before playback advanced is ignored',
      (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);

      proxy.healEvents.add(ProxyHeal.reboundNewPort);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(decoder.opened, hasLength(1));
      expect(find.byType(PlayerErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a lost source during a switch is left to the switch',
      (tester) async {
    final switchStart = Completer<void>();
    addTearDown(() {
      if (!switchStart.isCompleted) switchStart.complete();
    });
    final streamingContainer = buildPlayerScreenContainer(
      server: _server(directPlay: false, holdSwitchStart: switchStart),
      connectionState: HarnessLink.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: proxy,
    );
    addTearDown(streamingContainer.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, streamingContainer, decoder);
      await _playTo75(tester, decoder);
      final binding =
          tester.state(find.byType(PlayerScreen)) as RemotePlayerBinding;

      // A seek past the transcoded window restarts the session, which the
      // held start keeps in flight.
      unawaited(binding.seek(const Duration(seconds: 600)));
      await tester.pump(const Duration(milliseconds: 100));
      final healsBefore = proxy.healCalls;
      decoder.loseSource();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(proxy.healCalls, healsBefore,
          reason: 'the loss must not start a reopen of its own');
      expect(find.byType(PlayerErrorView), findsNothing);

      switchStart.complete();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets('a lost source before playback started does not reopen',
      (tester) async {
    await mockHttpResponse(() async {
      await _mount(tester, container, decoder);
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);

      decoder.loseSource();
      await tester.pump();
      await tester.pump();

      expect(decoder.opened, hasLength(1));

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });

  testWidgets(
      'a lost source or heal while casting leaves the local player alone',
      (tester) async {
    final sessions = StreamController<CastSession?>();
    addTearDown(sessions.close);
    final castingContainer = buildPlayerScreenContainer(
      server: _server(),
      connectionState: HarnessLink.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxy,
      castSessionStream: sessions.stream,
    );
    addTearDown(castingContainer.dispose);

    await mockHttpResponse(() async {
      await _mount(tester, castingContainer, decoder);
      await _playTo75(tester, decoder);
      final healsBefore = proxy.healCalls;

      sessions.add(const CastSession(
        device: testDevice,
        mediaInfo: CastMediaInfo(
          title: 'The Long Aurora',
          duration: Duration(seconds: 5400),
          position: Duration.zero,
        ),
        playbackState: CastPlaybackState.playing,
        connectionState: CastConnectionState.connected,
      ));
      await tester.pump();
      expect(castingContainer.read(isCastingProvider), isTrue);

      decoder.loseSource();
      proxy.healEvents.add(ProxyHeal.reboundNewPort);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(decoder.opened, hasLength(1));
      expect(proxy.healCalls, healsBefore);
      expect(find.byType(PlayerErrorView), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }, responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits);
  });
}
