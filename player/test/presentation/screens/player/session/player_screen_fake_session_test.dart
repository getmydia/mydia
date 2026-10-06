import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/widgets/video_controls/cast_chrome_icon.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

import '../../../../test_utils/probed_tracks.dart';
import '../../../../test_utils/scripted_mydia_transport.dart';
import '../../../../test_utils/toast_harness.dart';
import '../player_screen_test_harness.dart';
import 'fake_playback_session.dart';

class _RecordingPlatformPlayer extends PlatformPlayer {
  _RecordingPlatformPlayer()
      : super(configuration: const PlayerConfiguration());

  final _handle = Completer<int>();
  Media? opened;

  @override
  Future<int> get handle => _handle.future;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = playable as Media;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      tracks: probedTracks(),
    );
    durationController.add(state.duration);
    positionController.add(state.position);
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
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
}

const _mydiaOnly = [
  'StreamingCandidates',
  'StartStreamingSession',
  'UpdateMovieProgress',
  'MovieDetail',
];

/// Records which Mydia playback operations were sent.
ScriptedMydiaTransport _recordingServer(List<String> operations) {
  return ScriptedMydiaTransport((request, _) {
    if (_mydiaOnly.contains(request.operation)) {
      operations.add(request.operation);
    }
    if (request.operation == 'MovieDetail') {
      return movieDetailResponse(positionSeconds: 0);
    }
    if (request.operation == 'MovieSegments') return movieSegmentsResponse();
    if (request.operation == 'SubtitleTrackSettings') {
      return subtitleTrackSettingsResponse();
    }
    if (request.operation == 'MovieSubtitlePreference') {
      return subtitlePreferenceResponse();
    }
    if (request.operation == 'StreamingCandidates') {
      return streamingCandidatesResponse(directPlay: true, duration: 5400);
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

void main() {
  castPillTests();

  testWidgets('positive control: the Mydia session does issue those operations',
      (tester) async {
    final operations = <String>[];
    final container = buildPlayerScreenContainer(
      server: _recordingServer(operations),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);
    final fake = _RecordingPlatformPlayer();

    await pumpPlayerScreen(
      tester,
      container,
      createPlayer: () => Player(platformPlayer: fake),
    );
    await pumpUntil(tester, () => fake.opened != null);

    expect(operations, contains('StreamingCandidates'));
    expect(operations, contains('MovieDetail'));

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('plays what the session resolves and reports through it',
      (tester) async {
    final operations = <String>[];
    final container = buildPlayerScreenContainer(
      connectionState: conn.ConnectionState.direct(),
      server: _recordingServer(operations),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);
    final session = FakePlaybackSession();
    final fake = _RecordingPlatformPlayer();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: toastLayerBuilder,
        home: PlayerScreen(
          mediaId: 'm1',
          mediaType: 'movie',
          fileId: 'part-1',
          title: 'Invented Film',
          session: session,
          createPlayer: () => Player(platformPlayer: fake),
        ),
      ),
    ));
    await pumpUntil(tester, () => fake.opened != null);

    expect(session.prepared, 1);
    expect(fake.opened!.uri, 'https://fake.test/v.mkv');
    expect(fake.opened!.httpHeaders, {'X-Plex-Token': 'tok'});
    await pumpUntil(tester, () => session.progress.starts.isNotEmpty);
    expect(session.progress.starts.single, ('movie', 'm1'));
    for (final mydiaOnly in _mydiaOnly) {
      expect(operations, isNot(contains(mydiaOnly)), reason: mydiaOnly);
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(session.transport.ends, greaterThan(0),
        reason: 'leaving the screen ends the stream');
  });

  testWidgets('a session with a season offers the next episode by its route',
      (tester) async {
    final container = buildPlayerScreenContainer(
      connectionState: conn.ConnectionState.direct(),
      server: _recordingServer(<String>[]),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);
    final session = _SeasonSession();
    final fake = _RecordingPlatformPlayer();
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => PlayerScreen(
          mediaId: 'e1',
          mediaType: 'episode',
          fileId: 'f1',
          showId: 's1',
          seasonNumber: 1,
          session: session,
          createPlayer: () => Player(platformPlayer: fake),
        ),
      ),
      GoRoute(
        path: '/fake/episode/:id',
        builder: (_, state) => Text('landed ${state.pathParameters['id']}'),
      ),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        builder: toastLayerBuilder,
        routerConfig: router,
      ),
    ));
    await pumpUntil(tester, () => fake.opened != null);
    await pumpUntil(tester, () => session.progress.starts.isNotEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    await pumpUntil(tester, () => find.text('landed e2').evaluate().isNotEmpty);
    expect(find.text('landed e2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

class _SeasonSession extends FakePlaybackSession {
  @override
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber) async => [
        const PlaybackEpisode(
            id: 'e1', seasonNumber: 1, episodeNumber: 1, fileIds: ['f1']),
        const PlaybackEpisode(
            id: 'e2',
            seasonNumber: 1,
            episodeNumber: 2,
            title: 'Invented Episode 2',
            fileIds: ['f2']),
      ];
}

class _CastableSession extends FakePlaybackSession {
  @override
  Set<PlaybackFeature> get features => const {PlaybackFeature.cast};
}

Future<void> _pumpWithSession(
  WidgetTester tester,
  FakePlaybackSession session,
) async {
  final container = buildPlayerScreenContainer(
    connectionState: conn.ConnectionState.direct(),
    server: _recordingServer(<String>[]),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
  );
  addTearDown(container.dispose);
  final fake = _RecordingPlatformPlayer();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: ProviderScope(
      overrides: [
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
      ],
      child: MaterialApp(
        builder: toastLayerBuilder,
        home: PlayerScreen(
          mediaId: 'm1',
          mediaType: 'movie',
          fileId: 'part-1',
          session: session,
          createPlayer: () => Player(platformPlayer: fake),
        ),
      ),
    ),
  ));
  await pumpUntil(tester, () => fake.opened != null);
  await tester.pump(const Duration(milliseconds: 300));
}

void castPillTests() {
  testWidgets('a session without the cast feature shows no cast pill',
      (tester) async {
    await _pumpWithSession(tester, FakePlaybackSession());
    expect(find.byKey(CastChromeIcon.iconKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('positive control: a session with the cast feature has one',
      (tester) async {
    await _pumpWithSession(tester, _CastableSession());
    expect(find.byKey(CastChromeIcon.iconKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
