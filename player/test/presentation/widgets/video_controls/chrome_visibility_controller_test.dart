// The key handler in player_screen.dart sits above ChromeVisibility in the
// tree, so it cannot read the private `_visible` field that decides whether
// an arrow press means "seek" or "move focus". This controller is the handle
// that lifts out, without moving the state itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

Widget _host(ChromeVisibilityController controller) => MaterialApp(
      home: Scaffold(
        body: ChromeVisibility(
          controller: controller,
          isPlaying: true,
          isSeeking: false,
          autoHide: const Duration(days: 1),
          onTrafficLightsHidden: (_) {},
          child: const SizedBox.expand(),
        ),
      ),
    );

void main() {
  testWidgets('starts visible, matching the chrome mounting shown',
      (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    expect(controller.visible, isTrue);
  });

  testWidgets('hide() drives the chrome hidden and reports it', (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    controller.hide();
    await tester.pumpAndSettle();

    expect(controller.visible, isFalse);
  });

  testWidgets('show() brings it back', (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    controller.hide();
    await tester.pumpAndSettle();
    controller.show();
    await tester.pumpAndSettle();

    expect(controller.visible, isTrue);
  });

  testWidgets('notifies listeners on each transition', (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    await tester.pumpWidget(_host(controller));
    controller.hide();
    await tester.pumpAndSettle();
    controller.show();
    await tester.pumpAndSettle();

    expect(notifications, 2);
  });

  testWidgets('is inert once detached, so a late call cannot throw',
      (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(controller.hide, returnsNormally);
    expect(controller.visible, isTrue);
  });
}
