// Regression coverage for a dispose()-during-tracks-wait bug in
// `_openPlayerAndStart`: `dispose()` may run while the method is suspended
// on `await awaitRealTracks(...)` -- it nulls `_player`, disposes the
// player and the progress service. Continuing past that point still holds
// the (now-disposed) `Player` in a local variable and keeps using it, which
// throws once autoplay reaches `player.play()` against stream controllers
// `PlatformPlayer.dispose()` already closed.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// A media_kit player whose `open()` never reports a real track, so
/// `awaitRealTracks` in `_openPlayerAndStart` genuinely suspends on
/// `player.stream.tracks` instead of resolving instantly from `current` --
/// giving the test room to dispose the screen while that wait is still
/// pending. Mirrors `player_screen_first_frame_timeline_test.dart`'s
/// `_FakePlatformPlayer`, minus the track emission in `open`.
class _NeverProbesPlatformPlayer extends PlatformPlayer {
  _NeverProbesPlatformPlayer()
      : super(configuration: const PlayerConfiguration());

  // `VideoController` waits for a native output this test does not render.
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  bool openCalled = false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openCalled = true;
    // No track emission: `awaitRealTracks` must actually wait rather than
    // resolve immediately from `current`.
  }

  /// What `_openPlayerAndStart` calls once `widget.autoplay` (the default)
  /// carries the wait past its guard. Before the fix this runs against an
  /// already-disposed player: `PlatformPlayer.dispose()` (invoked
  /// fire-and-forget from `State.dispose()`) closes `playingController`
  /// synchronously, and `.add` on a closed `StreamController` throws.
  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  // `_onTracksChanged`/`_detectTracks` can reach this for the default
  // probed subtitle tracks; the base class throws `UnimplementedError`.
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}
}

/// A direct-play movie load with no HLS session, no subtitle preference and
/// no segments -- the same minimal script other player_screen tests use to
/// reach a playing screen with the least ceremony.
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
  /// inside the body's own scope -- see
  /// `player_screen_first_frame_timeline_test.dart` for why that timing
  /// matters.
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
      'disposing the screen while _openPlayerAndStart awaits real tracks '
      'does not throw', (tester) async {
    final fake = _NeverProbesPlatformPlayer();
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

      await pumpUntil(tester, () => fake.openCalled);
      // `pumpUntil` gives up silently after its try budget instead of
      // failing, so without this the test could unmount below having never
      // actually reached `open()` -- and pass vacuously, having proven
      // nothing about disposing mid-`awaitRealTracks`.
      expect(fake.openCalled, isTrue,
          reason: 'sanity check: open() must have run before this test '
              'disposes the screen, or the rest of this test proves nothing '
              'about the tracks-wait race');
      // A couple more pumps for the microtasks between `open()` returning
      // and `awaitRealTracks` subscribing to `player.stream.tracks` to
      // settle, without letting the (3s native) timeout resolve the wait
      // first.
      await tester.pump();
      await tester.pump();

      // Unmount while `_openPlayerAndStart` is still suspended on
      // `awaitRealTracks`. This nulls `_player` and disposes `fake`
      // (closing its stream controllers), which makes `awaitRealTracks`'s
      // subscription see `onDone` and resolve the wait shortly after.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.pump();
    });

    // No exception should escape to the framework's error zone...
    expect(tester.takeException(), isNull);
    // ...and `_initializePlayer`'s own try/catch, which would otherwise
    // swallow the exact crash this guards against (`player.play()` against
    // a disposed player's already-closed stream controller), must not have
    // caught one either.
    expect(
      logged.where((l) => l.contains('Error initializing player')),
      isEmpty,
      reason: 'continuing to use the player/progress service past dispose() '
          'must not throw once `_openPlayerAndStart` bails out early',
    );
  });
}
