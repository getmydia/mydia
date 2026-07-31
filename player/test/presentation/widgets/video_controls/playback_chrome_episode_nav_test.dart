// Guards PlaybackChrome's own episode-nav gate — a `metrics.touchTargets`
// check inside `_PlaybackChromeState.build` that isn't exercised anywhere
// else. `chrome_panel_overflow_test.dart` and `chrome_panel_golden_test.dart`
// both construct `ChromePanel` directly, bypassing `PlaybackChrome` entirely,
// so neither would notice if this gate were ever reverted or loosened.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings — safe to
/// construct inside `flutter test`. Same shape as
/// `gesture_chrome_composition_test.dart`'s fake (kept separate, not shared,
/// since neither file exports it and duplicating ~15 lines is cheaper than
/// introducing a new shared test-only import).
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration duration) async {}
}

void main() {
  group('PlaybackChrome episode-nav gate', () {
    late Player player;
    late int previousCalls;
    late int nextCalls;

    setUp(() {
      player = Player(platformPlayer: _FakePlatformPlayer());
      previousCalls = 0;
      nextCalls = 0;
    });

    tearDown(() => player.dispose());

    Widget host(double width) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 600,
              child: PlaybackChrome(
                player: player,
                timeline: StreamTimeline.zero,
                onPreviousEpisode: () => previousCalls++,
                onNextEpisode: () => nextCalls++,
              ),
            ),
          ),
        );

    testWidgets(
        'at a desktop width (touchTargets false), episode-nav buttons are '
        'wired into the transport and fire the supplied callbacks',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(1600));
      await tester.pumpAndSettle();

      expect(
        find.byKey(TransportSurface.previousEpisodeKey),
        findsOneWidget,
      );
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsOneWidget);

      await tester.tap(find.byKey(TransportSurface.previousEpisodeKey));
      await tester.tap(find.byKey(TransportSurface.nextEpisodeKey));
      expect(previousCalls, 1);
      expect(nextCalls, 1);
    });

    testWidgets(
        'at a mobile width (touchTargets true), the transport drops to '
        'play/pause only — episode-nav (and seek) buttons are gone, not '
        'just disabled', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host(400));
      await tester.pumpAndSettle();

      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
      expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);
      expect(find.byKey(TransportSurface.back10Key), findsNothing);
      expect(find.byKey(TransportSurface.forward10Key), findsNothing);

      // No RenderFlex overflow or any other exception at this width.
      expect(tester.takeException(), isNull);
    });
  });
}
