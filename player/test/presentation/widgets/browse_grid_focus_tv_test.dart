// BrowseGrid remembers its place: DOWN from a filter-chip row enters the grid
// at its first cell, moves inside the grid stay column-straight, and leaving
// for the chip row and coming back returns to the cell that left.
//
// A chip row (its own FocusMemoryRegion) above a real BrowseGrid of 30 cells,
// under the policy the shell's content region installs. The pair sits in a
// 1100px-wide box inside a 1920px view, the width a television content area
// has beside the sidebar, which gives the grid 6 columns
// (`libraryCrossAxisCount(1100)`); the view alone would give it 8.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/focus/region_traversal_policy.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/browse_grid.dart';

const double _contentWidth = 1100;

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; CI runs it in the '
          '"Run television-tier tests" step.';

  String focused() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  group('BrowseGrid focus memory (requires MYDIA_FORCE_TV=true)', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      expect(libraryCrossAxisCount(_contentWidth), 6);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: RegionTraversalPolicy(
                requestFocusCallback: FocusMemory.requestFocus,
              ),
              child: FocusScope(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: _contentWidth,
                    child: Column(
                      children: [
                        // Chips are narrower than cells, so the chip
                        // geometrically above cell 2 is not chip 0: only the
                        // chip row's memory lands UP from cell 2 on chip 0.
                        FocusMemoryRegion(
                          debugLabel: 'chips',
                          child: Row(
                            children: [
                              for (var i = 0; i < 6; i++)
                                FocusMemoryItem(
                                  id: 'chip-$i',
                                  index: i,
                                  child: Focus(
                                    debugLabel: 'chip-$i',
                                    child: const SizedBox(
                                      width: 100,
                                      height: 48,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: BrowseGrid(
                            itemCount: 30,
                            scrollTopPadding: 16,
                            itemId: (i) => 'item-$i',
                            itemBuilder: (context, i) => Focus(
                              debugLabel: 'item-$i',
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'enters at the first cell, moves column-straight, and returns to the '
      'cell that left the grid',
      (tester) async {
        await pumpScreen(tester);
        FocusManager.instance.rootScope.descendants
            .singleWhere((n) => n.debugLabel == 'chip-0')
            .requestFocus();
        await tester.pumpAndSettle();
        expect(focused(), 'chip-0');

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'item-0');

        await press(tester, LogicalKeyboardKey.arrowRight);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(focused(), 'item-2');

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'item-8');

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'item-2');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'chip-0');

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'item-2');
      },
    );
  }, skip: skipReason);
}
