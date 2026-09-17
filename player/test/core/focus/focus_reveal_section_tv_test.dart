// UP into the Home hero must show the whole hero, not only the button that
// took focus. Flutter's directional move reveals just the focused node, and
// the hero's buttons sit at its bottom, so the badge, title and backdrop
// stayed above the screen.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_reveal_section.dart';
import 'package:player/core/player/input_capabilities.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; CI runs it in the '
          '"Run television-tier tests" step.';

  group('FocusRevealSection (requires MYDIA_FORCE_TV=true)', () {
    late ScrollController controller;
    late FocusNode play;
    late FocusNode info;
    late FocusNode card;

    /// A 400px hero with two buttons along its bottom, above a 600px block
    /// holding one card. The viewport is 540px, so the page scrolls.
    ///
    /// [disableAnimations] wraps the scroll view in a `MediaQuery` requesting
    /// reduced motion, built from the ambient one so the real view size is
    /// preserved.
    Future<void> pumpPage(
      WidgetTester tester, {
      bool disableAnimations = false,
    }) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      controller = ScrollController();
      play = FocusNode(debugLabel: 'play');
      info = FocusNode(debugLabel: 'info');
      card = FocusNode(debugLabel: 'card');
      addTearDown(controller.dispose);
      addTearDown(play.dispose);
      addTearDown(info.dispose);
      addTearDown(card.dispose);

      final scrollView = CustomScrollView(
        controller: controller,
        slivers: [
          SliverToBoxAdapter(
            child: FocusRevealSection(
              child: SizedBox(
                height: 400,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Focus(
                        focusNode: play,
                        child: const SizedBox(width: 100, height: 40),
                      ),
                      const SizedBox(width: 12),
                      Focus(
                        focusNode: info,
                        child: const SizedBox(width: 100, height: 40),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 600,
              child: Align(
                alignment: Alignment.topLeft,
                child: Focus(
                  focusNode: card,
                  child: const SizedBox(width: 150, height: 200),
                ),
              ),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: !disableAnimations
                ? scrollView
                : Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(disableAnimations: true),
                      child: scrollView,
                    ),
                  ),
          ),
        ),
      );
    }

    testWidgets('UP into the section scrolls its top into view',
        (tester) async {
      await pumpPage(tester);

      // The card is at the top of the viewport and the hero's buttons are
      // just above it, off screen.
      controller.jumpTo(400);
      card.requestFocus();
      await tester.pumpAndSettle();
      expect(card.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      expect(play.hasFocus, isTrue);
      // Without the section, Flutter stops at 360: the button's own top.
      expect(controller.offset, 0);
    });

    testWidgets('moving between buttons inside the section does not scroll',
        (tester) async {
      await pumpPage(tester);

      play.requestFocus();
      await tester.pumpAndSettle();

      // Both buttons stay fully visible at this offset, so any scroll after
      // the move can only come from the section revealing itself again.
      controller.jumpTo(100);
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(info.hasFocus, isTrue);
      expect(controller.offset, 100);
    });

    testWidgets(
        'UP into the section with reduced motion lands at the revealed '
        'position with no animation to settle', (tester) async {
      await pumpPage(tester, disableAnimations: true);

      // Same setup as the first test: the card is at the top of the
      // viewport and the hero's buttons are just above it, off screen.
      controller.jumpTo(400);
      card.requestFocus();
      await tester.pumpAndSettle();
      expect(card.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      // A single pump, not pumpAndSettle: with reduced motion the reveal
      // has no animation to settle, so the scroll must already be at its
      // final position after one frame.
      await tester.pump();

      expect(play.hasFocus, isTrue);
      expect(controller.offset, 0);
    });
  }, skip: skipReason);
}
