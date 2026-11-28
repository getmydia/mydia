// The key handler in player_screen.dart sits above ChromeVisibility in the
// tree, so it cannot read the private `_visible` field that decides whether
// an arrow press means "seek" or "move focus". This controller is the handle
// that lifts out, without moving the state itself.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

Widget _host(ChromeVisibilityController controller) => MaterialApp(
  home: Scaffold(
    body: ChromeVisibility(
      controller: controller,
      isPlaying: true,
      isSeeking: false,
      autoHide: const Duration(days: 1),
      onWindowButtonsHidden: (_) {},
      child: const SizedBox.expand(),
    ),
  ),
);

void main() {
  testWidgets('starts visible, matching the chrome mounting shown', (
    tester,
  ) async {
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

  testWidgets('is inert once detached, so a late call cannot throw', (
    tester,
  ) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    expect(controller.hide, returnsNormally);
    expect(controller.visible, isTrue);
  });

  group('attached', () {
    test('false before any ChromeVisibility is pumped', () {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      expect(controller.attached, isFalse);
    });

    testWidgets('true while one is mounted', (tester) async {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller));

      expect(controller.attached, isTrue);
    });

    testWidgets('false again after it is unmounted', (tester) async {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(controller.attached, isFalse);
    });
  });

  // The property `PlayerScreen.build` actually gates the back button's
  // `PopScope.canPop` on. A screen phase with no chrome mounted at all, such
  // as loading, an error screen, or the cast placeholder, must let a back
  // press through rather than swallow it as if there were an OSD to
  // dismiss, since `visible` alone cannot tell "no chrome" from "chrome up
  // and showing" (both read `true`). `blocksBack` is what closes that gap.
  group('blocksBack', () {
    test('false while detached, so a back press is never swallowed before '
        'the chrome exists', () {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      expect(controller.attached, isFalse);
      expect(controller.blocksBack, isFalse);
    });

    testWidgets('true once mounted and visible', (tester) async {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller));

      expect(controller.blocksBack, isTrue);
    });

    testWidgets('false once mounted but hidden', (tester) async {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller));
      controller.hide();
      await tester.pumpAndSettle();

      expect(controller.blocksBack, isFalse);
    });

    testWidgets('false again once unmounted, even though visible reports '
        'true again the instant it detaches', (tester) async {
      final controller = ChromeVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(controller));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));

      expect(
        controller.visible,
        isTrue,
        reason:
            'sanity check: this is exactly the case a bare '
            '`!visible` gate gets wrong',
      );
      expect(controller.blocksBack, isFalse);
    });
  });

  // The player screen listens from a `ListenableBuilder` above the chrome
  // (its back-press `canPop`). A pause arriving while the chrome is hidden
  // shows it from didUpdateWidget, mid-build, and notifying then marked that
  // ancestor dirty during the build: an assertion in debug, a stale `canPop`
  // in release. The playback E2E hit it in the subtitle test.
  testWidgets('a show from a rebuild reaches an ancestor listener after the '
      'build', (tester) async {
    final controller = ChromeVisibilityController();
    addTearDown(controller.dispose);
    // What the ancestor saw the last time it built. It rebuilds during the
    // pause's own pumpWidget too (a new widget), but that runs before the
    // chrome's didUpdateWidget and sees `false`: only the deferred
    // notification can make it build again and see `true`.
    bool? seenByAncestor;
    Widget host({required bool playing}) => MaterialApp(
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, child) {
          seenByAncestor = controller.visible;
          return child!;
        },
        child: Scaffold(
          body: ChromeVisibility(
            controller: controller,
            isPlaying: playing,
            isSeeking: false,
            autoHide: const Duration(days: 1),
            onWindowButtonsHidden: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(playing: true));
    controller.hide();
    await tester.pumpAndSettle();
    expect(controller.visible, isFalse);
    expect(seenByAncestor, isFalse);

    // Pausing shows the chrome from didUpdateWidget.
    await tester.pumpWidget(host(playing: false));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(controller.visible, isTrue);
    expect(
      seenByAncestor,
      isTrue,
      reason:
          'the ancestor has to be told about the shown chrome after the '
          'build, or its canPop stays stale',
    );
  });
}
