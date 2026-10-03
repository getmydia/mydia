import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/presentation/screens/player/player_screen.dart';

import '../../../../test_utils/probed_tracks.dart';
import '../../../../test_utils/stub_graphql_client.dart';
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

void main() {
  testWidgets('plays what the session resolves and reports through it',
      (tester) async {
    final operations = <String>[];
    final container = buildPlayerScreenContainer(
      connectionState: conn.ConnectionState.direct(),
      link: StubLink((request, _) {
        operations.add(request.operation.operationName ?? '');
        return <String, dynamic>{'__typename': 'RootQueryType'};
      }),
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
    for (final mydiaOnly in [
      'StreamingCandidates',
      'StartStreamingSession',
      'UpdateMovieProgress',
      'MovieDetail',
    ]) {
      expect(operations, isNot(contains(mydiaOnly)), reason: mydiaOnly);
    }

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(session.transport.ends, greaterThan(0),
        reason: 'leaving the screen ends the stream');
  });
}
