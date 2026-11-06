// Television-tier proof that the OSD's progress bar is a D-pad scrubber: it
// takes focus, a scrub holds the OSD up, the bubble floats above the bar,
// and the timecodes are legible from a sofa.
//
// Requires --dart-define=MYDIA_FORCE_TV=true. Without it the file skips
// itself; CI runs it in the "Run television-tier tests" step, which picks up
// every test/**/*_tv_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/player/scrub_controller.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_controls/scrub_bubble.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings, counting
/// play/pause toggles. This repo keeps one fake per file.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  int playOrPauses = 0;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playOrPause() async => playOrPauses++;

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
          'unless the whole test process is compiled with that define.';

  group(
      'PlaybackChrome scrubbing on the remote tier '
      '(requires MYDIA_FORCE_TV=true)', () {
    late _FakePlatformPlayer platform;
    late Player player;
    late FocusNode scrubberFocus;
    late ScrubController scrub;
    late List<Duration> commits;

    setUp(() {
      platform = _FakePlatformPlayer();
      player = Player(platformPlayer: platform);
      scrubberFocus = FocusNode(debugLabel: 'scrubber');
      commits = [];
      scrub = ScrubController(
        position: () => const Duration(minutes: 10),
        duration: () => const Duration(hours: 1),
        onCommit: (target) async => commits.add(target),
      );
    });

    tearDown(() {
      scrub.dispose();
      scrubberFocus.dispose();
      player.dispose();
    });

    Future<void> pumpChrome(
      WidgetTester tester, {
      bool episodeNavigation = false,
    }) async {
      // The 1280x720 canvas TvCanvas gives a television.
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlaybackChrome(
              player: player,
              timeline: StreamTimeline.zero,
              onSeekToReal: (_) async {},
              title: 'Harbor Lights',
              scrub: scrub,
              scrubberFocusNode: scrubberFocus,
              onPreviousEpisode: episodeNavigation ? () {} : null,
              onNextEpisode: episodeNavigation ? () {} : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Unmounts, then clears the controller's idle and settling timers, which
    /// the test binding would otherwise report as pending.
    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      scrub.reset();
    }

    bool isSeeking(WidgetTester tester) => tester
        .widget<ChromeVisibility>(find.byType(ChromeVisibility))
        .isSeeking;

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.pump();
    }

    testWidgets('draws the timecodes at television size', (tester) async {
      await pumpChrome(tester);

      for (final key in [
        PlaybackChrome.elapsedKey,
        PlaybackChrome.remainingKey
      ]) {
        expect(
          tester.widget<Text>(find.byKey(key)).style!.fontSize,
          PlaybackChrome.remoteTimeFontSize,
        );
      }
      await finish(tester);
    });

    testWidgets('a scrub holds the OSD up and shows the bubble until OK',
        (tester) async {
      await pumpChrome(tester);
      scrubberFocus.requestFocus();
      await tester.pump();

      await press(tester, LogicalKeyboardKey.arrowRight);

      expect(scrub.active, isTrue);
      expect(isSeeking(tester), isTrue);
      expect(find.byType(ScrubBubble), findsOneWidget);

      await press(tester, LogicalKeyboardKey.select);

      expect(commits, [const Duration(minutes: 10, seconds: 10)]);
      expect(isSeeking(tester), isFalse);
      expect(find.byType(ScrubBubble), findsNothing);
      await finish(tester);
    });

    testWidgets('up from the bar commits the scrub', (tester) async {
      await pumpChrome(tester);
      scrubberFocus.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowRight);

      await press(tester, LogicalKeyboardKey.arrowUp);

      expect(commits, [const Duration(minutes: 10, seconds: 10)]);
      await finish(tester);
    });

    /// The key of the `ControlButton` holding focus. Every OSD control
    /// shares the `ControlButton` debug label, so the key tells them apart.
    Key? focusedControlKey() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<ControlButton>()
        ?.key;

    // With the OSD hidden, LEFT or RIGHT starts a scrub and focuses the bar
    // directly, so the control bar above it has never held focus and has
    // nothing to remember. UP must still land on play/pause, the centred
    // control, and not on the lowest-indexed button: OK there would switch
    // episode or seek back instead of resuming.
    for (final episodeNavigation in [false, true]) {
      testWidgets(
          'UP after a scrub that bypassed the control bar lands on '
          'play/pause (episode navigation: $episodeNavigation)',
          (tester) async {
        await pumpChrome(tester, episodeNavigation: episodeNavigation);
        expect(
          find.byKey(TransportSurface.previousEpisodeKey),
          episodeNavigation ? findsOneWidget : findsNothing,
        );
        scrubberFocus.requestFocus();
        await tester.pump();
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(scrub.active, isTrue);

        await press(tester, LogicalKeyboardKey.arrowUp);

        expect(focusedControlKey(), TransportSurface.playPauseKey);
        await finish(tester);
      });
    }

    testWidgets('Play/Pause on the bar commits, then toggles playback',
        (tester) async {
      await pumpChrome(tester);
      scrubberFocus.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.arrowRight);

      await press(tester, LogicalKeyboardKey.mediaPlayPause);

      expect(commits, [const Duration(minutes: 10, seconds: 10)]);
      expect(platform.playOrPauses, 1);
      await finish(tester);
    });
  }, skip: skipReason);
}
