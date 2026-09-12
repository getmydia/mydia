// The reported defect: playback started and the OSD could not be brought back.
// Revealing it moved no focus, so the OSD appeared with no ring and the next
// press either did nothing visible or fired an invisible control.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

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
      // The restore in Step 9 hangs off this notification, so it is the one
      // dependency of that logic that can be pinned without mounting
      // PlayerScreen. ChromeVisibility is player-free by design, which is what
      // makes that possible.
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
  }, skip: skipReason);
}
