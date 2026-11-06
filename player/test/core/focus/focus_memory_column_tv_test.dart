// A FocusMemoryColumn steps UP and DOWN between its regions in the order the
// page declares them, wherever their nodes sit, and otherwise stays out of
// the way.
//
// The harness lays the sections out the way a detail page does: a lone
// button at the right ("Play"), a bar of buttons at the left below it, a
// wide rail below that, plus non-region nodes above and below. Left to the
// geometric search, DOWN from the lone button overlaps the rail and skips the
// bar. Every move goes through a policy carrying [FocusMemory.requestFocus],
// as the app installs it. Each focusable is a bare `Focus` labelled with its
// id, so `focused()` reads the id back.
//
// Requires --dart-define=MYDIA_FORCE_TV=true. The off-TV passthrough is in
// focus_memory_test.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/player/input_capabilities.dart';

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

  Future<void> focus(WidgetTester tester, String id) async {
    FocusManager.instance.rootScope.descendants
        .singleWhere((n) => n.debugLabel == id)
        .requestFocus();
    await tester.pumpAndSettle();
    expect(focused(), id);
  }

  Widget box(String id, double width, double height) => Focus(
        debugLabel: id,
        child: SizedBox(width: width, height: height),
      );

  /// A region of [ids], laid out in a row, each [width] wide.
  Widget region(List<String> ids, {double width = 100, double height = 80}) =>
      FocusMemoryRegion(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, id) in ids.indexed)
              FocusMemoryItem(id: id, index: i, child: box(id, width, height)),
          ],
        ),
      );

  group('FocusMemoryColumn (requires MYDIA_FORCE_TV=true)', () {
    Future<void> pumpPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(
            requestFocusCallback: FocusMemory.requestFocus,
          ),
          child: FocusMemoryColumn(
            child: Stack(
              children: [
                // Not a region: above the first section.
                Positioned(left: 1700, top: 0, child: box('top', 100, 80)),
                Positioned(left: 1700, top: 200, child: region(['play'])),
                Positioned(
                    left: 0, top: 400, child: region(['b0', 'b1', 'b2'])),
                // A region with nothing focusable is passed over.
                const Positioned(
                  left: 0,
                  top: 550,
                  child: FocusMemoryRegion(child: SizedBox(height: 10)),
                ),
                // Not a region, straight under the bar: where the geometric
                // search goes from it, so a column that stopped at the
                // empty region would show here.
                Positioned(left: 0, top: 600, child: box('loose', 300, 40)),
                Positioned(
                  left: 0,
                  top: 700,
                  child: region(
                    [for (var i = 0; i < 6; i++) 'c$i'],
                    width: 300,
                  ),
                ),
                // Not a region: below the last section.
                Positioned(left: 1700, top: 950, child: box('bottom', 100, 80)),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('DOWN and UP step through the sections in declared order',
        (tester) async {
      await pumpPage(tester);
      await focus(tester, 'play');

      // The geometric search would overlap c5, straight below.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'b0');
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(), 'b1');
      // The empty region between is passed over.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'c0');
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focused(), 'c2');

      // Each section is re-entered on the item that left it.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), 'b1');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'c2');
      await press(tester, LogicalKeyboardKey.arrowUp);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), 'play');
    });

    testWidgets('above the first section, traversal is geometric',
        (tester) async {
      await pumpPage(tester);
      await focus(tester, 'play');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), 'top');
    });

    testWidgets('below the last section, traversal is geometric',
        (tester) async {
      await pumpPage(tester);
      await focus(tester, 'c5');
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'bottom');
    });

    testWidgets('a press from outside every region is left to traversal',
        (tester) async {
      await pumpPage(tester);
      await focus(tester, 'bottom');

      // Straight above `bottom` is c5. A column acting here would have
      // nowhere to start from and would have to guess.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focused(), 'c0',
          reason: 'c5 is the geometric pick, and entering the rail lands on '
              'its first card');
    });

    testWidgets('a column inside a popup route never acts', (tester) async {
      await pumpPage(tester);
      await focus(tester, 'b0');
      final context = tester.element(find.byType(Stack).first);
      unawaited(showModalBottomSheet<void>(
        context: context,
        builder: (_) => SizedBox(
          height: 300,
          child: FocusMemoryColumn(
            child: Stack(
              children: [
                Positioned(left: 500, top: 0, child: region(['x0'])),
                Positioned(left: 0, top: 150, child: region(['y0', 'y1'])),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await focus(tester, 'x0');

      // As a page section, DOWN would land on y0. Inside the sheet it is the
      // geometric search's: y1 is the nearer of the two.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focused(), 'y1');
    });
  }, skip: skipReason);

  group('FocusMemoryItem (requires MYDIA_FORCE_TV=true)', () {
    testWidgets(
        'an item holding a control of its own is entered on itself, not '
        'on the control', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(
            requestFocusCallback: FocusMemory.requestFocus,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              box('above', 100, 80),
              FocusMemoryRegion(
                child: FocusMemoryItem(
                  id: 'card',
                  index: 0,
                  // A card with a menu button in its corner, as an episode
                  // card has. Flutter lists the button before the card.
                  child: Focus(
                    debugLabel: 'card',
                    child: SizedBox(
                      width: 300,
                      height: 200,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: box('menu', 40, 40),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await focus(tester, 'above');

      await press(tester, LogicalKeyboardKey.arrowDown);

      expect(focused(), 'card');
    });
  }, skip: skipReason);
}
