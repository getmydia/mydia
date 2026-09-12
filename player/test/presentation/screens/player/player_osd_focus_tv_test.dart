// The reported defect: playback started and the OSD could not be brought back.
// Revealing it moved no focus, so the OSD appeared with no ring and the next
// press either did nothing visible or fired an invisible control.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings, so the real
/// `PlayerScreen` can be mounted under `flutter test`. Mirrors
/// `player_screen_source_switch_test.dart`'s `_Decoder` — which is private to
/// that file, and this repo's convention is a local fake per file rather than
/// a shared test-only export.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  final opened = <Media>[];

  // `VideoController` waits for a native output this test does not render.
  // Keeping the handle unresolved avoids reaching native texture/FFI calls.
  final _handle = Completer<int>();

  @override
  Future<int> get handle => _handle.future;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    opened.add(playable as Media);
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

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration duration) async {
    state = state.copyWith(position: duration);
    positionController.add(duration);
  }
}

/// Opacity of the chrome's own fade, i.e. whether the OSD is on screen.
double _chromeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(ChromeVisibility.contentKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

/// The node the screen installs on its own `Focus` — the one focus returns to
/// when the OSD hides. It has no debug label, so it is reached through the
/// widget that carries the screen's key handler.
FocusNode _playerSurfaceNode(WidgetTester tester) => tester
    .widget<Focus>(
      find.byWidgetPredicate(
        (w) => w is Focus && w.autofocus && w.onKeyEvent != null,
      ),
    )
    .focusNode!;

/// Mounts the real `PlayerScreen` on a fake platform player and a stubbed
/// transport, and waits until its chrome is in the tree.
///
/// Mirrors `player_screen_source_switch_test.dart`'s setup: p2p because the
/// non-p2p branch resolves a media token from a provider the harness does not
/// override (it never completes under `flutter test`), and a stub that keeps
/// answering so a start/end-session request does not get a candidates payload.
Future<void> _mountPlayingScreen(WidgetTester tester) async {
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
  );
  addTearDown(container.dispose);

  await pumpPlayerScreen(
    tester,
    container,
    createPlayer: () => Player(platformPlayer: fake),
  );
  // `pumpUntil`, not `pumpAndSettle`: the loading spinner never settles.
  await pumpUntil(
      tester, () => find.byType(PlaybackChrome).evaluate().isNotEmpty);
}

/// Waits for the OSD to be fully on screen, then for it to auto-hide itself.
///
/// Both halves are needed. The reveal starts a fade-in, so right after it the
/// opacity is still 0.0 — waiting only for `0.0` there would return before the
/// chrome had even become visible, and the test would assert on a hide that
/// never happened.
///
/// Generous budget: the screen's own start sequence has to finish before
/// `isPlaying` is true, and only then does the 3s auto-hide timer start.
Future<void> _waitForChromeToHide(WidgetTester tester) async {
  await pumpUntil(tester, () => _chromeOpacity(tester) == 1.0, maxTries: 500);
  await pumpUntil(tester, () => _chromeOpacity(tester) == 0.0, maxTries: 500);
}

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('OSD focus ownership (requires MYDIA_FORCE_TV=true)', () {
    testWidgets('a supplied node owns focus on the play/pause button',
        (tester) async {
      final playPause = FocusNode(debugLabel: 'osd-play-pause');
      addTearDown(playPause.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransportSurface(
              isPlaying: true,
              onPlayPause: () {},
              playPauseFocusNode: playPause,
            ),
          ),
        ),
      );

      playPause.requestFocus();
      await tester.pump();

      expect(playPause.hasFocus, isTrue);
      final button = find.byKey(TransportSurface.playPauseKey);
      expect(button, findsOneWidget);
      // The node the shell asks for must be the one the button actually uses,
      // or revealing the chrome would focus a node nothing is listening to.
      //
      // `Focus.of` searches ancestors only, and the `FocusHighlight` that
      // installs the node is a *descendant* of the keyed `ControlButton`, so
      // the lookup starts from an element inside the highlight — the glyph —
      // rather than the button's own element.
      expect(
        Focus.of(tester.element(find.byIcon(Icons.pause_rounded))).hasFocus,
        isTrue,
      );
    });

    testWidgets('ControlButton still works with no supplied node',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ControlButton(
                icon: Icons.play_arrow_rounded, onTap: () => taps++),
          ),
        ),
      );

      await tester.tap(find.byType(ControlButton));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets(
        'hiding notifies the controller, which is what the player '
        'listens to in order to take focus back', (tester) async {
      // The restore hangs off this notification, so it is the one dependency
      // of that logic that can be pinned without mounting PlayerScreen.
      // ChromeVisibility is player-free by design, which is what makes that
      // possible; the composed behaviour is covered below.
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      var notifications = 0;
      controller.addListener(() => notifications++);

      await tester.pumpWidget(
        MaterialApp(
          home: ChromeVisibility(
            controller: controller,
            isPlaying: true,
            child: const SizedBox.expand(),
          ),
        ),
      );
      await tester.pump();

      expect(controller.visible, isTrue);

      controller.hide();
      await tester.pumpAndSettle();

      expect(controller.visible, isFalse);
      expect(notifications, greaterThan(0));
    });

    testWidgets(
        'revealing the OSD lands focus on play/pause, and the '
        'auto-hide hands it back to the player', (tester) async {
      await _mountPlayingScreen(tester);
      final playerSurface = _playerSurfaceNode(tester);

      // The reported defect starts here: playback running, OSD auto-hidden,
      // focus parked on the player's own node, which paints no ring.
      await _waitForChromeToHide(tester);
      expect(
        _chromeOpacity(tester),
        0.0,
        reason: 'the chrome must be hidden for the reveal to be what moves '
            'focus; with it visible an arrow press traverses instead',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'osd-play-pause',
        reason: 'revealing the OSD must land the viewer on a real, ringed '
            'control, not leave focus on the player node that paints nothing',
      );

      // Let the OSD auto-hide under the focused control. Without the restore,
      // focus stays on a control the viewer can no longer see, and the next OK
      // fires it invisibly.
      await _waitForChromeToHide(tester);
      // Flush the microtask `requestFocus` schedules: it is not applied
      // synchronously, so reading `hasFocus` right after it returns the
      // previous value.
      await tester.pump();

      expect(_chromeOpacity(tester), 0.0);
      // `same`, not `hasFocus`: `hasFocus` is true for an ancestor whenever a
      // descendant holds focus, and the player's node is the ancestor of the
      // whole body — including the chrome — so it would read true even with
      // focus still stranded on a control inside the OSD.
      expect(
        FocusManager.instance.primaryFocus,
        same(playerSurface),
        reason: 'an auto-hidden OSD must hand focus back to the player so a '
            'later press cannot activate an invisible control',
      );
    });

    testWidgets(
        'the auto-hide restores focus from any chrome control, '
        'not just play/pause', (tester) async {
      // Every chrome control is a focus stop under `ArrowIntent.traverse`, so
      // the viewer can be parked on, say, the subtitles button when the OSD
      // auto-hides. Asking only about the play/pause node would leave focus
      // stranded on that invisible control — the exact failure the restore
      // exists to prevent — which is why the screen asks whether focus is
      // anywhere inside the chrome.
      await _mountPlayingScreen(tester);
      final playerSurface = _playerSurfaceNode(tester);
      await _waitForChromeToHide(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final playPause = FocusManager.instance.primaryFocus;
      expect(playPause?.debugLabel, 'osd-play-pause');

      // Traverse off play/pause. The transport buttons all use the default
      // `ControlButton` label, so landing on one is what proves focus left
      // the play/pause node rather than merely staying put.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      final traversed = FocusManager.instance.primaryFocus;
      expect(
        traversed?.debugLabel,
        'ControlButton',
        reason: 'the arrow must move focus to a sibling chrome control for '
            'this test to exercise the restore from somewhere other than '
            'play/pause',
      );
      expect(identical(traversed, playPause), isFalse);

      await _waitForChromeToHide(tester);
      await tester.pump();

      expect(
        FocusManager.instance.primaryFocus,
        same(playerSurface),
        reason: 'focus must come back from whatever chrome control held it, '
            'not only from play/pause',
      );
    });

    testWidgets(
        'OK reveals the OSD when it is on screen but nothing in it '
        'is focused', (tester) async {
      // Reachable without touching an arrow key: the remote's own play/pause
      // key calls `_chromeVisibility.show()` and moves no focus, leaving the
      // OSD up with no ring. OK must still land the viewer on a control, which
      // is why the guard asks whether the chrome holds focus rather than
      // whether it is visible.
      await _mountPlayingScreen(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pump();

      expect(
        _chromeOpacity(tester),
        1.0,
        reason: 'the transport key puts the OSD on screen',
      );
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('osd-play-pause'),
        reason: 'and, before OK, deliberately focuses nothing inside it',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'osd-play-pause',
        reason: 'OK over a visible but unfocused OSD must land on a control '
            'rather than doing nothing at all',
      );
    });
  }, skip: skipReason);
}
