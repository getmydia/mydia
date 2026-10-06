// Coverage for PlayerScreen's Now Playing reports, which feed the macOS Dock
// menu. The publisher records state on every platform, so this runs on the
// Linux test host by reading `NowPlayingPublisher.current`.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/app_menu/now_playing.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/core/remote/remote_target_controller.dart';

import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

/// A media_kit player with no decoder that publishes tracks on open and
/// reports play and pause on its `playing` stream.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  bool opened = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened = true;
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: false,
      tracks: probedTracks(),
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(false);
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

/// The minimal direct-play movie script, as in
/// `player_screen_dispose_during_tracks_wait_test.dart`.
ScriptedMydiaTransport _server() {
  return ScriptedMydiaTransport((request, index) {
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
  testWidgets('reports playing, then paused, then clears on dispose',
      (tester) async {
    final fake = _FakePlatformPlayer();
    final container = buildPlayerScreenContainer(
      server: _server(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);
    final publisher = container.read(nowPlayingPublisherProvider);

    await pumpPlayerScreen(
      tester,
      container,
      createPlayer: () => Player(platformPlayer: fake),
    );
    await pumpUntil(tester, () => publisher.current?.isPlaying == true);

    expect(
      publisher.current,
      const NowPlaying(
        title: 'The Long Aurora',
        isPlaying: true,
        hasNext: false,
      ),
      reason: 'autoplay must be reported with the screen title; a movie '
          'has no next episode',
    );

    container.read(remoteTargetControllerProvider).submit(
          const TransportIntent(TransportAction.pause),
        );
    await pumpUntil(tester, () => publisher.current?.isPlaying == false);
    expect(publisher.current?.isPlaying, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(publisher.current, isNull,
        reason: 'a disposed player must leave the Dock with no controls');
  });
}
