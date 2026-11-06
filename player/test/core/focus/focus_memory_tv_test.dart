// A row remembers its place: entering a row vertically lands on the item that
// last had focus in it, whatever either row's scroll position, and a row never
// visited lands on its first item.
//
// The harness is three horizontal rails stacked in a column at television
// size, under a traversal group whose policy routes every move through
// [FocusMemory.requestFocus], which is how the app installs it. Each card is a
// bare `Focus` labelled with its item id, so `focused()` reads the id back.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/player/input_capabilities.dart';

const double _cardWidth = 300;
const double _rowHeight = 300;

List<String> _ids(int row, [int count = 12]) =>
    [for (var i = 0; i < count; i++) 'r$row-c$i'];

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; CI runs it in the '
          '"Run television-tier tests" step.';

  String focused() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

  FocusNode nodeFor(String id) {
    final node = FocusManager.instance.rootScope.descendants
        .where((n) => n.debugLabel == id)
        .toList();
    expect(node, hasLength(1), reason: 'expected exactly one node for $id');
    return node.single;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  group('FocusMemory (requires MYDIA_FORCE_TV=true)', () {
    late List<ScrollController> controllers;

    Widget card(String id, int index) => FocusMemoryItem(
          id: id,
          index: index,
          child: Focus(
            debugLabel: id,
            child: const SizedBox(width: _cardWidth, height: _rowHeight),
          ),
        );

    Widget row(
      int r,
      List<String> ids, {
      double? cacheExtent,
      Object? initialId,
    }) {
      return SizedBox(
        height: _rowHeight,
        child: FocusMemoryRegion(
          debugLabel: 'row-$r',
          initialId: initialId,
          child: ListView.builder(
            controller: controllers[r],
            scrollDirection: Axis.horizontal,
            scrollCacheExtent: cacheExtent == null
                ? null
                : ScrollCacheExtent.pixels(cacheExtent),
            itemCount: ids.length,
            itemBuilder: (context, i) => card(ids[i], i),
          ),
        ),
      );
    }

    Future<void> pumpRows(
      WidgetTester tester, {
      List<List<String>>? rows,
      double? cacheExtent,
      Map<int, Object>? initialIds,
    }) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final data = rows ?? [_ids(0), _ids(1), _ids(2)];
      await tester.pumpWidget(
        MaterialApp(
          home: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(
              requestFocusCallback: FocusMemory.requestFocus,
            ),
            child: Column(
              children: [
                for (var r = 0; r < data.length; r++)
                  row(
                    r,
                    data[r],
                    cacheExtent: cacheExtent,
                    initialId: initialIds?[r],
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      controllers = [for (var i = 0; i < 3; i++) ScrollController()];
    });

    tearDown(() {
      for (final c in controllers) {
        c.dispose();
      }
    });

    Future<void> focus(WidgetTester tester, String id) async {
      nodeFor(id).requestFocus();
      await tester.pumpAndSettle();
      expect(focused(), id);
    }

    testWidgets(
      'down then up returns to the starting card when rows are scrolled '
      'differently',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r0-c4');
        controllers[1].jumpTo(900);
        await tester.pumpAndSettle();

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('r1-'));
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'r0-c4');
      },
    );

    testWidgets(
      'entering a never-visited row lands on its first item',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r0-c4');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c0');
      },
    );

    testWidgets(
      'entering a never-visited row with an initial id lands on that item',
      (tester) async {
        await pumpRows(tester, initialIds: {1: 'r1-c3'});
        await focus(tester, 'r0-c4');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c3');
      },
    );

    testWidgets(
      'a remembered item wins over the initial id',
      (tester) async {
        await pumpRows(tester, initialIds: {1: 'r1-c3'});
        await focus(tester, 'r1-c1');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), startsWith('r0-'));
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c1');
      },
    );

    testWidgets(
      'an initial id that is not built falls back to the entry item',
      (tester) async {
        await pumpRows(tester, cacheExtent: 0, initialIds: {1: 'r1-c10'});
        expect(
          FocusManager.instance.rootScope.descendants
              .where((n) => n.debugLabel == 'r1-c10'),
          isEmpty,
          reason: 'c10 must be unbuilt for this test to mean anything',
        );
        await focus(tester, 'r0-c4');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c0');
      },
    );

    testWidgets(
      'entering a visited row lands on its remembered item',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r1-c6');
        await press(tester, LogicalKeyboardKey.arrowUp);
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(focused(), 'r0-c1');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c6');
      },
    );

    testWidgets(
      'remembered item that moved is followed by id',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r1-c6');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), startsWith('r0-'));

        final moved = _ids(1)..remove('r1-c6');
        moved.insert(0, 'r1-c6');
        await pumpRows(tester, rows: [_ids(0), moved, _ids(2)]);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c6');
      },
    );

    testWidgets(
      'removed item falls back to the nearest surviving index',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r1-c6');
        await press(tester, LogicalKeyboardKey.arrowUp);

        final removed = _ids(1)..remove('r1-c6');
        await pumpRows(tester, rows: [_ids(0), removed, _ids(2)]);

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c7');
      },
    );

    testWidgets(
      'remembered item outside the build cache falls back by index',
      (tester) async {
        await pumpRows(tester, cacheExtent: 0);
        controllers[1].jumpTo(1800);
        await tester.pumpAndSettle();
        await focus(tester, 'r1-c10');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), startsWith('r0-'));

        controllers[1].jumpTo(0);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.rootScope.descendants
              .where((n) => n.debugLabel == 'r1-c10'),
          isEmpty,
          reason: 'c10 must be unbuilt for this test to mean anything',
        );

        // At offset 0 with no cache extent, c0 through c6 are built (c6
        // straddles the right edge). The nearest built index to the
        // remembered 10 is 6; plain geometry from r0-c0 would pick r1-c0.
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c6');
        final rect = FocusManager.instance.primaryFocus!.rect;
        const screen = Rect.fromLTWH(0, 0, 1920, 1080);
        expect(screen.overlaps(rect), isTrue,
            reason: 'focused card $rect must be on screen');
      },
    );

    testWidgets(
      'up down up across three rows',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r1-c5');
        await focus(tester, 'r2-c3');

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'r1-c5');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'r0-c0');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r1-c5');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 'r2-c3');
      },
    );

    testWidgets(
      'an emptied row is skipped',
      (tester) async {
        await pumpRows(tester);
        await focus(tester, 'r1-c2');
        await pumpRows(tester, rows: [_ids(0), const [], _ids(2)]);

        await focus(tester, 'r0-c0');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('r2-'));
      },
    );

    testWidgets(
      'moves inside a bottom sheet are not redirected',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        late BuildContext pageContext;
        await tester.pumpWidget(
          MaterialApp(
            // Above the navigator, so the sheet's route sits inside the group
            // and its moves run through FocusMemory.requestFocus, as they do
            // under the app's shell.
            builder: (context, child) => FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(
                requestFocusCallback: FocusMemory.requestFocus,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                pageContext = context;
                return Column(
                  children: [
                    row(0, _ids(0)),
                    row(1, _ids(1)),
                  ],
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await focus(tester, 'r1-c2');

        Widget sheetButton(String id) => Focus(
              debugLabel: id,
              child: const SizedBox(width: 200, height: 80),
            );
        unawaited(
          showModalBottomSheet<void>(
            context: pageContext,
            builder: (_) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [sheetButton('s0-a'), sheetButton('s0-b')]),
                Row(children: [sheetButton('s1-a'), sheetButton('s1-b')]),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(isInsidePopupRoute(nodeFor('s0-a')), isTrue);
        expect(isInsidePopupRoute(nodeFor('r1-c2')), isFalse);

        await focus(tester, 's0-b');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('s1-'));
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), startsWith('s0-'));
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), startsWith('s'));
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('s'));
      },
    );

    // The test above has no regions inside the sheet, so nothing there could
    // be redirected even without the popup guard. Here the sheet's rows are
    // regions with a remembered item, so only the guard keeps DOWN on the
    // geometric choice.
    testWidgets(
      'regions inside a bottom sheet do not redirect',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        late BuildContext pageContext;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(
                requestFocusCallback: FocusMemory.requestFocus,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) {
                pageContext = context;
                return const SizedBox.expand();
              },
            ),
          ),
        );

        Widget sheetRow(int r) => FocusMemoryRegion(
              child: Row(
                children: [
                  for (var i = 0; i < 2; i++)
                    FocusMemoryItem(
                      id: 's$r-$i',
                      index: i,
                      child: Focus(
                        debugLabel: 's$r-$i',
                        child: const SizedBox(width: 200, height: 80),
                      ),
                    ),
                ],
              ),
            );
        unawaited(
          showModalBottomSheet<void>(
            context: pageContext,
            builder: (_) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [sheetRow(0), sheetRow(1)],
            ),
          ),
        );
        await tester.pumpAndSettle();

        await focus(tester, 's1-1');
        await focus(tester, 's0-0');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), 's1-0');
      },
    );

    testWidgets(
      'firstVisible entry picks the first on-screen item',
      (tester) async {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final list = ScrollController();
        addTearDown(list.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: FocusTraversalGroup(
              policy: ReadingOrderTraversalPolicy(
                requestFocusCallback: FocusMemory.requestFocus,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: FocusMemoryRegion(
                      entry: FocusMemoryEntry.firstVisible,
                      child: ListView.builder(
                        controller: list,
                        itemCount: 30,
                        itemBuilder: (context, i) => FocusMemoryItem(
                          id: 'item-$i',
                          index: i,
                          child: Focus(
                            debugLabel: 'item-$i',
                            child: const SizedBox(height: 100),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Entering from below: the geometric search alone would
                  // pick the bottom-most visible row, and `first` would pick
                  // a cached row above the viewport, so only firstVisible
                  // lands on item 4.
                  const Focus(
                    debugLabel: 'below',
                    child: SizedBox(height: 100, width: 400),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        list.jumpTo(400);
        await tester.pumpAndSettle();
        expect(
          FocusManager.instance.rootScope.descendants
              .any((n) => n.debugLabel == 'item-3'),
          isTrue,
          reason: 'item 3 must be built (cached) off-screen for this test',
        );

        await focus(tester, 'below');
        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'item-4');
      },
    );
  }, skip: skipReason);
}
