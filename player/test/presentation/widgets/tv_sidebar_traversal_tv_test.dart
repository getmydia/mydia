// The reported defect, asserted end to end: on a television, LEFT from the
// leftmost card in a rail must land on the sidebar, and RIGHT from the sidebar
// must return to the card that left it.
//
// The shell is reconstructed at the television size rather than pumped whole:
// AppShell's real tree needs an authenticated provider graph, and what is under
// test here is the boundary, not the graph.
//
// The boundary itself is the real [SidebarFocusBoundary] the shell uses, not a
// pair of callbacks written here. That matters for the third test: a fixture
// that hardcoded "focus the first card" on the way back would pass even if the
// boundary stopped remembering where focus came from, which is the property
// this round trip exists to prove.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/region_traversal_policy.dart';
import 'package:player/core/focus/sidebar_focus_boundary.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; forcedTv is a compile-time '
          'flag (bool.fromEnvironment), so this file is a deliberate no-op '
          'unless the whole test process is compiled with that define. CI '
          'runs it explicitly in the "Run television-tier tests" step.';

  group('Sidebar region boundary (requires MYDIA_FORCE_TV=true)', () {
    late FocusNode sidebarSelected;
    late FocusNode firstCard;
    late FocusNode secondCard;
    late FocusScopeNode contentScope;
    late FocusScopeNode sidebarScope;
    late SidebarFocusBoundary boundary;

    /// Creates the shell's nodes and boundary.
    ///
    /// Separate from [buildShell] so a test can rebuild the shell — the way a
    /// route change does — while keeping the same sidebar node, region scope
    /// and boundary: what is under test there is the boundary surviving a
    /// change of content, which a fresh boundary on every build would hide.
    void createShellNodes() {
      sidebarSelected = FocusNode(debugLabel: 'sidebar-selected');
      firstCard = FocusNode(debugLabel: 'first-card');
      secondCard = FocusNode(debugLabel: 'second-card');
      addTearDown(sidebarSelected.dispose);
      addTearDown(firstCard.dispose);
      addTearDown(secondCard.dispose);

      contentScope = FocusScopeNode(debugLabel: 'content-scope');
      sidebarScope = FocusScopeNode(debugLabel: 'sidebar-scope');
      addTearDown(contentScope.dispose);
      addTearDown(sidebarScope.dispose);

      boundary = SidebarFocusBoundary(
        sidebarNode: sidebarSelected,
        contentScope: contentScope,
      );
    }

    Widget buildShell({Widget? content}) {
      return MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              // Sidebar region.
              FocusTraversalGroup(
                policy: RegionTraversalPolicy(
                  onExit: (direction) => direction == TraversalDirection.right
                      ? boundary.focusContent()
                      : false,
                ),
                child: FocusScope(
                  node: sidebarScope,
                  child: SizedBox(
                    width: 260,
                    child: Column(
                      children: [
                        SidebarRow(
                          icon: Icons.home_rounded,
                          selectedIcon: Icons.home_rounded,
                          label: 'Home',
                          isSelected: true,
                          focusNode: sidebarSelected,
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Content region: two rails, stacked the way Home stacks them.
              // The cards are stacked rather than placed side by side because
              // that is what puts the left press at the *region* edge: with two
              // cards side by side, LEFT from the right-hand one is an ordinary
              // in-region move to the left-hand one, the boundary is never
              // consulted, and the round trip this file exists to prove cannot
              // be exercised at all.
              Expanded(
                child: FocusTraversalGroup(
                  policy: RegionTraversalPolicy(
                    onExit: (direction) => direction == TraversalDirection.left
                        ? boundary.focusSidebar()
                        : false,
                  ),
                  child: FocusScope(
                    node: contentScope,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: content ??
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Focus(
                                focusNode: firstCard,
                                child: const SizedBox(width: 160, height: 240),
                              ),
                              Focus(
                                focusNode: secondCard,
                                child: const SizedBox(width: 160, height: 240),
                              ),
                            ],
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('LEFT from the leftmost card focuses the sidebar',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      createShellNodes();
      await tester.pumpWidget(buildShell());
      firstCard.requestFocus();
      await tester.pump();
      expect(firstCard.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(sidebarSelected.hasFocus, isTrue);
    });

    testWidgets('RIGHT from the sidebar returns to the card', (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      createShellNodes();
      await tester.pumpWidget(buildShell());

      // The viewer reaches the sidebar by pressing left, so the origin has to
      // be established the same way. Focusing the sidebar node directly would
      // ask the boundary to return to a card it was never told about, and it
      // rightly declines that rather than guessing a card.
      firstCard.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(sidebarSelected.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(firstCard.hasFocus, isTrue);
    });

    testWidgets('RIGHT returns the card that left, not the first card',
        (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      createShellNodes();
      await tester.pumpWidget(buildShell());

      secondCard.requestFocus();
      await tester.pump();
      expect(secondCard.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(sidebarSelected.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // This is the assertion that fails if the boundary stops recording where
      // focus came from: without it, RIGHT lands on the first card.
      expect(secondCard.hasFocus, isTrue);
      expect(firstCard.hasFocus, isFalse);
    });

    testWidgets(
        'RIGHT after navigating from the sidebar lands in the new route, '
        'whose remembered card is gone', (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      createShellNodes();
      await tester.pumpWidget(buildShell());

      secondCard.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(sidebarSelected.hasFocus, isTrue);

      // Activating the row runs `context.go`, which replaces the routed child:
      // an entirely new focusable takes the old ones' place and the node the
      // boundary remembered is disposed. The sidebar row is untouched and
      // keeps focus, which is exactly the state a viewer is in when they press
      // RIGHT to leave the sidebar.
      final newRouteCard = FocusNode(debugLabel: 'new-route-card');
      addTearDown(newRouteCard.dispose);
      await tester.pumpWidget(
        buildShell(
          content: Center(
            child: Focus(
              focusNode: newRouteCard,
              child: const SizedBox(width: 160, height: 240),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(sidebarSelected));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // Without the fallback this press is dropped: the boundary reports no
      // move, the policy calls the key unhandled, and focus stays in the
      // sidebar.
      expect(FocusManager.instance.primaryFocus, same(newRouteCard));
    });
  }, skip: skipReason);
}
