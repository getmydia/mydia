// Television-tier proof that the playback OSD drops the controls a remote has
// no use for (Back, Cast, mute and volume, Fullscreen) and takes the remote's
// auto-hide: a longer delay that every key press restarts.
//
// Requires --dart-define=MYDIA_FORCE_TV=true. Without it the file skips
// itself; CI runs it in the "Run television-tier tests" step.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings. Same shape
/// as `playback_chrome_test.dart`'s fake; this repo keeps one per file.
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
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('PlaybackChrome on the remote tier (requires MYDIA_FORCE_TV=true)', () {
    late Player player;

    setUp(() => player = Player(platformPlayer: _FakePlatformPlayer()));
    tearDown(() => player.dispose());

    /// Every control the chrome can show is wired, so anything missing below
    /// was dropped by the tier gate rather than by an absent callback.
    Future<void> pumpChrome(WidgetTester tester) async {
      // The 1280x720 canvas TvCanvas gives a television.
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackChrome(
              player: player,
              timeline: StreamTimeline.zero,
              onSeekToReal: (_) async {},
              title: 'Harbor Lights',
              onBack: () {},
              castAction: const Icon(Icons.cast_rounded),
              onCastTap: () {},
              onFullscreenTap: () {},
              onSubtitleTap: () {},
              onAudioTap: () {},
              audioTrackCount: 2,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('drops Back, Cast, the volume controls and Fullscreen',
        (tester) async {
      await pumpChrome(tester);

      expect(find.byKey(ChromeTopBar.backKey), findsNothing);
      expect(find.byKey(ChromeTopBar.castKey), findsNothing);
      expect(find.byKey(VolumeSurface.muteKey), findsNothing);
      expect(find.byKey(VolumeSurface.sliderKey), findsNothing);
      expect(find.byKey(SecondaryCluster.fullscreenKey), findsNothing);
    });

    testWidgets('keeps the title, the transport and the track controls',
        (tester) async {
      await pumpChrome(tester);

      expect(find.byKey(ChromeTopBar.titleKey), findsOneWidget);
      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
      expect(find.byKey(TransportSurface.back10Key), findsOneWidget);
      expect(find.byKey(TransportSurface.forward10Key), findsOneWidget);
      expect(find.byKey(SecondaryCluster.subtitlesKey), findsOneWidget);
      expect(find.byKey(SecondaryCluster.audioKey), findsOneWidget);
    });

    testWidgets('hands ChromeVisibility the remote auto-hide', (tester) async {
      await pumpChrome(tester);

      final visibility =
          tester.widget<ChromeVisibility>(find.byType(ChromeVisibility));
      expect(visibility.autoHide, ChromeVisibility.remoteAutoHide);
      expect(visibility.restartOnKeyActivity, isTrue);
    });
  }, skip: skipReason);
}
