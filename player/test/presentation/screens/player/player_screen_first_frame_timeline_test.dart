// Coverage for Task 10's Play-to-first-frame marks: `_playTimeline` picks up
// `planned`, `opened`, `tracks_ready` and `first_frame` across a normal
// direct-play load, and the one `playback:` summary line carries all of
// them. `_playTimeline` is private state with no public getter, so this
// reads it the same way `player_screen_resume_offset_test.dart` reads
// `_timeline`: through the genuine production `debugPrint` calls, not a
// reflection hack.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/probed_tracks.dart';
import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// A media_kit player with no decoder behind it, carrying just enough state
/// for `PlayerScreen` to reach a playing `PlaybackChrome` under
/// `flutter test` -- mirrors `player_screen_stats_panel_test.dart`'s
/// `_FakePlatformPlayer`, plus [emitWidth] for this file's own purpose.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  // `VideoController` waits for a native output this test does not render.
  // Keeping the handle unresolved avoids reaching native texture/FFI calls.
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    state = state.copyWith(
      duration: const Duration(seconds: 90),
      position: Duration.zero,
      playing: play,
    );
    durationController.add(state.duration);
    positionController.add(state.position);
    playingController.add(play);
    // What mpv publishes as soon as it has probed the file. Without this,
    // `awaitRealTracks` never sees a real track and burns its full 3s cap,
    // which would let `tracks_ready` race behind a synchronously-emitted
    // `first_frame` instead of preceding it the way a real load does.
    state = state.copyWith(tracks: probedTracks());
    tracksController.add(state.tracks);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  /// What mpv reports once a frame has actually decoded. `widthController`
  /// is `@protected` on `PlatformPlayer`, reachable here because this class
  /// extends it; `player.stream.width` is this same controller's stream.
  void emitWidth(int width) => widthController.add(width);
}

/// A direct-play movie load with no HLS session, no subtitle preference and
/// no segments -- the same minimal script `player_screen_stats_panel_test.dart`
/// uses to reach a playing screen with the least ceremony.
StubLink _link() {
  return StubLink((request, index) {
    if (isOperation(request, 'MovieDetail')) {
      return movieDetailResponse(positionSeconds: 0);
    }
    if (isOperation(request, 'MovieSegments')) return movieSegmentsResponse();
    if (isOperation(request, 'SubtitleTrackSettings')) {
      return subtitleTrackSettingsResponse();
    }
    if (isOperation(request, 'MovieSubtitlePreference')) {
      return subtitlePreferenceResponse();
    }
    if (isOperation(request, 'StreamingCandidates')) {
      return streamingCandidatesResponse(directPlay: true, duration: 5400);
    }
    return <String, dynamic>{
      '__typename': 'RootMutationType',
      'updateMovieProgress': null,
    };
  });
}

void main() {
  /// Collects `debugPrint` output for the duration of [body], restoring it
  /// inside the body's own scope rather than via `tearDown` -- see
  /// `player_screen_resume_offset_test.dart` for why that timing matters.
  Future<T> withCapturedDebugPrint<T>(
    List<String> into,
    Future<T> Function() body,
  ) async {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) into.add(message);
    };
    try {
      return await body();
    } finally {
      debugPrint = original;
    }
  }

  testWidgets(
      'a first real frame logs one playback: summary carrying every mark',
      (tester) async {
    final fake = _FakePlatformPlayer();
    final container = buildPlayerScreenContainer(
      link: _link(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    final logged = <String>[];
    await withCapturedDebugPrint(logged, () async {
      await pumpPlayerScreen(
        tester,
        container,
        createPlayer: () => Player(platformPlayer: fake),
      );
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);

      // The first real frame: media_kit reports a positive width once mpv has
      // actually decoded one, distinct from the zero/null it carries while
      // still opening.
      fake.emitWidth(1920);

      await pumpUntil(
        tester,
        () => logged.any((l) => l.startsWith('playback:')),
      );
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    final summaries = logged.where((l) => l.startsWith('playback:')).toList();
    expect(summaries, hasLength(1),
        reason: 'StartupTimeline.logOnce must only ever print once per load, '
            'not once per mark and not again from dispose');

    final summary = summaries.single;
    expect(summary, contains('planned='));
    expect(summary, contains('opened='));
    expect(summary, contains('tracks_ready='));
    expect(summary, contains('first_frame='));
  });

  testWidgets(
      'no first frame still logs one summary, from dispose, with no '
      'first_frame mark', (tester) async {
    final fake = _FakePlatformPlayer();
    final container = buildPlayerScreenContainer(
      link: _link(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    final logged = <String>[];
    await withCapturedDebugPrint(logged, () async {
      await pumpPlayerScreen(
        tester,
        container,
        createPlayer: () => Player(platformPlayer: fake),
      );
      await pumpUntil(
          tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);

      // No frame ever arrives on this player. Disposing the screen must
      // still flush the timeline exactly once, with whatever marks it
      // reached, instead of leaking the subscription or staying silent.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    final summaries = logged.where((l) => l.startsWith('playback:')).toList();
    expect(summaries, hasLength(1));
    expect(summaries.single, isNot(contains('first_frame=')));
  });
}
