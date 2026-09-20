// Regression coverage for the fix-round bug the plan's review found:
// `ref.listen`'s callback for `statsOverlayEnabledProvider` does not itself
// trigger a rebuild, so flipping the flag on mid-playback needs `setState`
// on both directions or the panel can be internally armed
// (`_statsCollector` non-null, sampling) while nothing on screen shows it —
// masked in production by *some* unrelated rebuild eventually coming along,
// but not guaranteed, and not within this test's single deliberate pump.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/stats_overlay_setting.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/playback_stats/stats_panel.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings, so the
/// real `PlayerScreen` can be mounted under `flutter test`. Mirrors
/// `player_osd_focus_tv_test.dart`'s `_FakePlatformPlayer` — private to
/// that file, and this repo's convention is a local fake per file rather
/// than a shared test-only export.
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
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  /// Whether anything is currently subscribed to `player.stream.buffer`.
  ///
  /// `bufferController` is `@protected` on `PlatformPlayer`, reachable here
  /// because this class extends it; `PlatformPlayer.stream` wraps it in a
  /// single `late`-initialised `distinct()` stream built once at
  /// construction (not recomputed per access), so this reflects every
  /// listener of `player.stream.buffer` for this player's lifetime, not
  /// just this fake's own bookkeeping.
  ///
  /// The proxy this test needs: `PlaybackStatsCollector.start()` is the
  /// only thing that subscribes to it once verification has stopped and the
  /// cast placeholder has unmounted the chrome's `VideoProgressBar` (the
  /// only other subscriber in `lib/`), so this stays true exactly as long
  /// as the collector is actually armed and sampling, not merely as long as
  /// the panel happens to be on screen.
  bool get hasBufferListener => bufferController.hasListener;
}

/// Mounts the real `PlayerScreen` direct-playing a file, with the stats
/// overlay flag backed by a real `SettingsService` over an in-memory
/// [MockAuthStorage] so the test can flip it after mount — the default
/// harness leaves `coreSettingsServiceProvider` unoverridden, which every
/// other `PlayerScreen` test relies on, so this passes it explicitly rather
/// than changing that default.
///
/// [castSessionStream] threads straight through to
/// `buildPlayerScreenContainer`, which is the only way to drive
/// `isCastingProvider` under test (see that parameter's own dartdoc); left
/// null, casting never starts and `castSessionProvider` reports `null`
/// throughout, exactly like every other caller of this helper.
///
/// Returns the fake platform player alongside the container, not just the
/// container, so a caller can inspect what is actually still subscribed to
/// the player's streams (`_FakePlatformPlayer.hasBufferListener`) -- the
/// only way to tell "the collector stopped" from "the panel is merely
/// off screen" from outside `_PlayerScreenState`, which is private to
/// `player_screen.dart`.
Future<(ProviderContainer, _FakePlatformPlayer)> _mountPlayingScreen(
  WidgetTester tester, {
  Stream<CastSession?>? castSessionStream,
}) async {
  final storage = MockAuthStorage();
  final settings = SettingsService(storage: storage);
  final fake = _FakePlatformPlayer();
  final container = buildPlayerScreenContainer(
    link: StubLink((request, index) {
      if (index == 0) return movieDetailResponse(positionSeconds: 0);
      if (index == 1) return movieSegmentsResponse();
      if (index == 2) return subtitleTrackSettingsResponse();
      if (index == 3) return subtitlePreferenceResponse();
      if (index == 4) {
        return streamingCandidatesResponse(directPlay: true, duration: 5400);
      }
      final variables = request.variables;
      if (variables.containsKey('strategy')) {
        return startStreamingSessionResponse(
          sessionId: 'sess-$index',
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
    }),
    connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'test-node'),
    castManager: CapturingCastSessionManager(),
    proxyService: TrackingLocalProxyService(),
    coreSettingsService: settings,
    castSessionStream: castSessionStream,
  );
  addTearDown(container.dispose);

  await pumpPlayerScreen(
    tester,
    container,
    createPlayer: () => Player(platformPlayer: fake),
  );
  await pumpUntil(
      tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);

  // Lets `statsOverlayEnabledProvider`'s own async `build()` (the initial
  // `getStatsOverlayEnabled()` read) resolve before the test mutates it,
  // matching `stats_overlay_setting_test.dart`'s own setup.
  await container.read(statsOverlayEnabledProvider.future);

  return (container, fake);
}

void main() {
  testWidgets(
      'turning the flag on mid-playback shows the panel after one pump plus '
      "the collector's first tick, with no other rebuild to mask it",
      (tester) async {
    final (container, _) = await _mountPlayingScreen(tester);

    expect(find.byType(StatsPanel), findsNothing,
        reason: 'the flag starts off, so nothing has armed the collector');

    await container.read(statsOverlayEnabledProvider.notifier).set(true);
    // Exactly one pump for the listener's own rebuild, then one tick for
    // the collector's first sample -- not `pumpAndSettle`, which would
    // paper over a missing `setState` by pumping until something else
    // incidentally rebuilds the tree.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(StatsPanel), findsOneWidget,
        reason: 'the on branch must setState like the off branch does, or '
            'the collector starts sampling with nothing on screen to show '
            'it');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('turning the flag off mid-playback hides the panel',
      (tester) async {
    final (container, _) = await _mountPlayingScreen(tester);
    await container.read(statsOverlayEnabledProvider.notifier).set(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(StatsPanel), findsOneWidget);

    await container.read(statsOverlayEnabledProvider.notifier).set(false);
    await tester.pump();

    expect(find.byType(StatsPanel), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // The bug this covers: `ref.listen<bool>(isCastingProvider, ...)` called
  // `_stopVerification()` on cast start but not `_stopStatsCollector()`, so
  // the collector's `Timer.periodic` kept sampling once a second for the
  // whole cast session. Invisible (the cast placeholder replaces the body
  // that holds the panel) is not the same as inactive, so the assertion
  // below checks the collector's own subscription, not what is on screen.
  testWidgets(
      'starting a cast session stops the stats collector, not just the '
      'panel', (tester) async {
    final sessions = StreamController<CastSession?>.broadcast();
    // Registered before `_mountPlayingScreen` runs (which registers
    // `container.dispose` itself), so LIFO teardown disposes the container
    // first and closes `sessions` second -- the same ordering
    // `player_screen_source_switch_test.dart` uses for the same reason: a
    // broadcast `close()` waits for every listener to be delivered its done
    // event, and only disposing the container first cancels Riverpod's own
    // subscription to this stream.
    addTearDown(sessions.close);

    final (container, fake) = await _mountPlayingScreen(
      tester,
      castSessionStream: sessions.stream,
    );

    await container.read(statsOverlayEnabledProvider.notifier).set(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(StatsPanel), findsOneWidget);
    expect(fake.hasBufferListener, isTrue,
        reason: 'sanity check: the armed collector subscribes to the '
            'buffer stream, or the assertion below would pass vacuously');

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

    expect(find.byType(StatsPanel), findsNothing,
        reason: 'the cast placeholder replaces the body that holds it');

    // `_stopStatsCollector` (like `_stopVerification` beside it) disposes
    // fire-and-forget (`unawaited`), and `PlaybackStatsCollector.dispose`
    // cancels its two stream subscriptions -- position, then buffer --
    // behind their own `await`s. That chain never resolves under plain
    // `tester.pump()`, however many times or however much fake duration is
    // elapsed (verified empirically: 100 iterations of `pumpUntil` and 20
    // bare pumps both leave it pending); it only progresses on the real
    // event loop, which is exactly what `tester.runAsync` exists to reach.
    // Not a test artifact to route around: it is a genuine, harmless async
    // gap between "the timer that drove mpv reads is already cancelled"
    // (synchronous, inside `dispose()` before its first `await`, so the
    // actual defect this test guards is fixed the instant
    // `_stopStatsCollector` is called) and "the now-pointless stream
    // subscriptions have finished unsubscribing".
    await tester.runAsync(() async {
      for (var i = 0; i < 40 && fake.hasBufferListener; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    // Brings the binding back in sync with the real time `runAsync` just
    // spent, per its own contract.
    await tester.pump();

    expect(fake.hasBufferListener, isFalse,
        reason: '_stopStatsCollector must run alongside _stopVerification '
            'on cast start, or the collector keeps sampling mpv for the '
            'whole cast session with nothing on screen to show for it');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // CodeRabbit's finding on this PR (outside-diff comment on
  // player_screen.dart:4805-4810): this listener had no casting guard of
  // its own, so toggling the stats flag off then on again while a cast
  // session was already active re-armed the collector against `_player`,
  // which is still the backgrounded local player -- casting hides it
  // behind the cast placeholder, it never gets torn down. The
  // `isCastingProvider` listener above only intercepts the *transition*
  // into casting (the test above this one); a flag flip mid-session never
  // fires it, so this listener needs its own guard, reaching the same
  // defect by a different path.
  testWidgets(
      'toggling the flag off then on during an active cast session does '
      'not re-arm the collector', (tester) async {
    final sessions = StreamController<CastSession?>.broadcast();
    // Same LIFO teardown reasoning as the test above: dispose the
    // container before closing the broadcast stream it is still
    // subscribed to.
    addTearDown(sessions.close);

    final (container, fake) = await _mountPlayingScreen(
      tester,
      castSessionStream: sessions.stream,
    );

    await container.read(statsOverlayEnabledProvider.notifier).set(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(fake.hasBufferListener, isTrue,
        reason: 'sanity check: the armed collector subscribes to the '
            'buffer stream, or the assertions below would pass vacuously');

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

    // Same async gap the test above documents: `dispose()` cancels its
    // subscriptions behind their own `await`s, which only progresses on the
    // real event loop.
    await tester.runAsync(() async {
      for (var i = 0; i < 40 && fake.hasBufferListener; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();
    expect(fake.hasBufferListener, isFalse,
        reason: 'sanity check: cast start already stopped the collector, '
            'or the assertions below would pass vacuously');

    // Off then on, both while the cast session is still active. Neither
    // transitions `isCastingProvider`, so the listener above never fires
    // for either flip -- this listener is the only one that can see it.
    await container.read(statsOverlayEnabledProvider.notifier).set(false);
    await tester.pump();
    await container.read(statsOverlayEnabledProvider.notifier).set(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(fake.hasBufferListener, isFalse,
        reason: 'the on branch must not re-arm the collector while '
            'casting -- it would sample the hidden local player for the '
            'rest of the cast session, the same defect the '
            'isCastingProvider listener exists to prevent, reached here by '
            'flipping the flag instead of starting a new cast session');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  // The cast-end half of this scenario -- ending the session and confirming
  // the collector re-arms once local playback resumes -- is deliberately
  // not covered here. `_restartLocalPlayback` disposes `_player`, and
  // media_kit's own `PlatformPlayer.dispose` closes every stream
  // controller on it, including `bufferController`; `_mountPlayingScreen`
  // hands `createPlayer` a closure over a single `fake` shared for the
  // whole test, so the player `_initializePlayer` constructs afterwards
  // would reuse that already-closed instance and throw on its first
  // `open()`. `StubLink`'s handler here is also positional
  // (`index == 0..3`), scripted for exactly one startup sequence; a
  // restart repeats the same four queries and would fall through to the
  // catch-all `updateMovieProgress` response instead. Covering the restart
  // needs a `createPlayer` that mints a fresh fake per call and a
  // `StubLink` that answers by operation name instead of position, the way
  // `player_screen_cast_skip_segments_test.dart`'s `_link` does -- real
  // harness changes, not a two-line addition, so left for a follow-up
  // rather than bent to fit here.
}
