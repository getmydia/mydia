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
}

/// Mounts the real `PlayerScreen` direct-playing a file, with the stats
/// overlay flag backed by a real `SettingsService` over an in-memory
/// [MockAuthStorage] so the test can flip it after mount — the default
/// harness leaves `coreSettingsServiceProvider` unoverridden, which every
/// other `PlayerScreen` test relies on, so this passes it explicitly rather
/// than changing that default.
Future<ProviderContainer> _mountPlayingScreen(WidgetTester tester) async {
  final storage = MockAuthStorage();
  final settings = SettingsService(storage: storage);
  final fake = _FakePlatformPlayer();
  final container = buildPlayerScreenContainer(
    link: StubLink((request, index) {
      if (index == 0) return movieDetailResponse(positionSeconds: 0);
      if (index == 1) return movieSegmentsResponse();
      if (index == 2) return subtitleTrackSettingsResponse();
      if (index == 3) {
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

  return container;
}

void main() {
  testWidgets(
      'turning the flag on mid-playback shows the panel after one pump plus '
      "the collector's first tick, with no other rebuild to mask it",
      (tester) async {
    final container = await _mountPlayingScreen(tester);

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
    final container = await _mountPlayingScreen(tester);
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
}
