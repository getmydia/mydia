// The reported defect, asserted end to end: on a television, LEFT from the
// leftmost card in a rail must land on the sidebar, and RIGHT from the sidebar
// must return to the card that left it.
//
// The shell is reconstructed at the television size rather than pumped whole:
// AppShell's real tree needs an authenticated provider graph, and what is under
// test here is the boundary, not the graph.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/region_traversal_policy.dart';
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

    Widget buildShell() {
      sidebarSelected = FocusNode(debugLabel: 'sidebar-selected');
      firstCard = FocusNode(debugLabel: 'first-card');
      addTearDown(sidebarSelected.dispose);
      addTearDown(firstCard.dispose);

      final contentScope = FocusScopeNode(debugLabel: 'content-scope');
      final sidebarScope = FocusScopeNode(debugLabel: 'sidebar-scope');
      addTearDown(contentScope.dispose);
      addTearDown(sidebarScope.dispose);

      return MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              // Sidebar region.
              FocusTraversalGroup(
                policy: RegionTraversalPolicy(
                  onExit: (direction) {
                    if (direction != TraversalDirection.right) return false;
                    firstCard.requestFocus();
                    return true;
                  },
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
              // Content region, with a rail of one focusable card.
              Expanded(
                child: FocusTraversalGroup(
                  policy: RegionTraversalPolicy(
                    onExit: (direction) {
                      if (direction != TraversalDirection.left) return false;
                      sidebarSelected.requestFocus();
                      return true;
                    },
                  ),
                  child: FocusScope(
                    node: contentScope,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Focus(
                        focusNode: firstCard,
                        child: const SizedBox(width: 160, height: 240),
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

      await tester.pumpWidget(buildShell());
      sidebarSelected.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      expect(firstCard.hasFocus, isTrue);
    });
  }, skip: skipReason);
}
