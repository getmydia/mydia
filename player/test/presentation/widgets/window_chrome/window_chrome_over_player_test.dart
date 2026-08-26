import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/core/window/window_buttons_hidden.dart';
import 'package:player/core/window/window_controller.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/window_chrome/desktop_window_chrome.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';

import '../../../core/window/fake_window_controller.dart';

/// `debugDefaultTargetPlatformOverride` is reset in a synchronous `finally`
/// rather than `addTearDown`, for the reason `desktop_window_chrome_test.dart`
/// records: the binding verifies foundation debug vars are unset the moment
/// the test body returns, before package:test unwinds its teardown queue.
Future<void> _onLinux(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
    windowButtonsHiddenSignal.value = false;
  }
}

/// The real app tree, minus the routing: `DesktopWindowChrome` outermost with
/// the player's `ChromeVisibility` underneath it, both reading and writing the
/// app-wide `windowButtonsHidden` signal exactly as production wires them.
Future<void> _pumpPlayingPlayer(
  WidgetTester tester, {
  FakeWindowController? controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DesktopWindowChrome(
        layout: ValueNotifier(
          const DecorationLayout(
            start: [],
            end: [
              WindowButton.minimize,
              WindowButton.maximize,
              WindowButton.close,
            ],
          ),
        ),
        controller: controller ?? FakeWindowController(),
        fullscreen: ValueNotifier(false),
        child: const ChromeVisibility(
          isPlaying: true,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(width: 200, height: 60, child: Text('chrome')),
          ),
        ),
      ),
    ),
  );
}

final Finder _closeButton =
    find.byKey(WindowButtonWidget.keyFor(WindowButton.close));

void main() {
  testWidgets(
      'the window buttons survive a mouse moving onto them mid-playback',
      (tester) async {
    await _onLinux(() async {
      await _pumpPlayingPlayer(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      expect(_closeButton, findsOneWidget,
          reason: 'precondition: buttons are shown');

      // Aim at the close button, the way a viewer reaching for it does.
      await gesture.moveTo(tester.getCenter(_closeButton));
      await tester.pumpAndSettle();

      expect(
        _closeButton,
        findsOneWidget,
        reason: 'the button was deleted out from under the cursor aiming at '
            'it, so the click lands on nothing',
      );

      // The player is entitled to consider its own chrome hidden here: from
      // where it sits, under an opaque strip, the pointer did leave. What it
      // is not entitled to do is take the window buttons with it.
      expect(windowButtonsHidden.value, isTrue);
    });
  });

  testWidgets('the bare drag band keeps the buttons alive too', (tester) async {
    await _onLinux(() async {
      await _pumpPlayingPlayer(tester);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      // Well clear of the buttons on the right: a viewer heading for the
      // close button crosses this on the way, and the buttons have to still
      // be there when they arrive.
      await gesture.moveTo(const Offset(120, kLinuxWindowChromeHeight / 2));
      await tester.pumpAndSettle();

      expect(_closeButton, findsOneWidget);
    });
  });

  testWidgets('reaching for the top strip restores buttons already hidden',
      (tester) async {
    await _onLinux(() async {
      await _pumpPlayingPlayer(tester);

      // No pointer at all: the auto-hide timer runs out on its own, which is
      // how a viewer who has not touched the mouse for three seconds gets
      // here.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(_closeButton, findsNothing,
          reason: 'precondition: playback hid the buttons');

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(
        location: const Offset(400, kLinuxWindowChromeHeight / 2),
      );
      addTearDown(gesture.removePointer);
      await tester.pumpAndSettle();

      expect(_closeButton, findsOneWidget,
          reason: 'a pointer in the title strip must be able to summon the '
              'window buttons; nothing underneath can, because the strip '
              'takes the hover');
    });
  });

  testWidgets('leaving the strip lets the buttons hide again', (tester) async {
    await _onLinux(() async {
      await _pumpPlayingPlayer(tester);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(
        location: const Offset(400, kLinuxWindowChromeHeight / 2),
      );
      addTearDown(gesture.removePointer);
      await tester.pumpAndSettle();
      expect(_closeButton, findsOneWidget);

      // Out through the top of the window, so nothing underneath is hovered
      // on the way out and the hidden state stands.
      await gesture.moveTo(const Offset(400, -50));
      await tester.pumpAndSettle();

      expect(_closeButton, findsNothing,
          reason: 'the pin is a reprieve while the cursor is there, not a '
              'permanent override of the hidden state');
    });
  });

  testWidgets('the click a viewer aims at the close button actually lands',
      (tester) async {
    await _onLinux(() async {
      final window = FakeWindowController();
      await _pumpPlayingPlayer(tester, controller: window);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(400, 300));
      addTearDown(gesture.removePointer);
      await tester.pump();

      await gesture.moveTo(tester.getCenter(_closeButton));
      await tester.pumpAndSettle();
      await tester.tap(_closeButton);
      await tester.pump();

      expect(window.closeCalls, 1);
    });
  });

  testWidgets('the hover-tracking strip does not swallow the window drag',
      (tester) async {
    await _onLinux(() async {
      final window = FakeWindowController();
      await _pumpPlayingPlayer(tester, controller: window);

      // Below the 8px resize edge, clear of the buttons: the drag band.
      await tester.dragFrom(
        const Offset(300, kLinuxWindowChromeHeight / 2),
        const Offset(40, 40),
      );
      await tester.pump();

      expect(window.startDraggingCalls, 1);

      // This test drives no mouse, so `ChromeVisibility`'s auto-hide timer is
      // still armed. Let it fire, or the binding fails the test on a pending
      // timer at teardown.
      await tester.pump(const Duration(seconds: 4));
    });
  });

  testWidgets('the top resize edge still resizes through the strip',
      (tester) async {
    await _onLinux(() async {
      final window = FakeWindowController();
      await _pumpPlayingPlayer(tester, controller: window);

      // The hover strip is drawn over this 8px zone, so it is the one place
      // `opaque: false` has to be doing its job for the edge to survive.
      await tester.dragFrom(const Offset(300, 4), const Offset(0, 30));
      await tester.pump();

      expect(window.startResizingCalls, [WindowEdge.top]);

      await tester.pump(const Duration(seconds: 4));
    });
  });
}
