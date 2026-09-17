// The region boundary's hand-off. Confinement itself is a property of the
// FocusScope the caller installs, so it is asserted by the shell test in
// tv_sidebar_traversal_tv_test.dart;
// what is asserted here is the contract on its own: a direction the region
// cannot satisfy is offered to onExit, handled directions are not
// re-dispatched, and a left or right move never leaves the focused node's row.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/region_traversal_policy.dart';

void main() {
  testWidgets('offers an unsatisfiable direction to onExit', (tester) async {
    final seen = <TraversalDirection>[];
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        seen.add(direction);
        return true;
      },
    );

    final left = FocusNode(debugLabel: 'left');
    final right = FocusNode(debugLabel: 'right');
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: FocusTraversalGroup(
          policy: policy,
          child: Row(
            children: [
              Focus(
                  focusNode: left,
                  child: const SizedBox(width: 50, height: 50)),
              Focus(
                  focusNode: right,
                  child: const SizedBox(width: 50, height: 50)),
            ],
          ),
        ),
      ),
    );

    left.requestFocus();
    await tester.pump();
    expect(left.hasFocus, isTrue);

    // Leftmost node, so left has nowhere to go inside the region.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(seen, [TraversalDirection.left]);
  });

  testWidgets('does not consult onExit for a direction it can satisfy',
      (tester) async {
    var calls = 0;
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        calls++;
        return true;
      },
    );

    final left = FocusNode(debugLabel: 'left');
    final right = FocusNode(debugLabel: 'right');
    addTearDown(left.dispose);
    addTearDown(right.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: FocusTraversalGroup(
          policy: policy,
          child: Row(
            children: [
              Focus(
                  focusNode: left,
                  child: const SizedBox(width: 50, height: 50)),
              Focus(
                  focusNode: right,
                  child: const SizedBox(width: 50, height: 50)),
            ],
          ),
        ),
      ),
    );

    left.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(right.hasFocus, isTrue);
    expect(calls, 0);
  });

  testWidgets('an unhandled exit leaves focus where it was', (tester) async {
    final policy = RegionTraversalPolicy(onExit: (direction) => false);

    final only = FocusNode(debugLabel: 'only');
    addTearDown(only.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: FocusTraversalGroup(
          policy: policy,
          child: Focus(
              focusNode: only, child: const SizedBox(width: 50, height: 50)),
        ),
      ),
    );

    only.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(only.hasFocus, isTrue);
  });

  /// Two rows in one region. [upperLeft] is the left inset of the upper
  /// row's only node, [lowerLefts] the left insets of the lower row's nodes.
  /// Every node is 50x50 and the rows do not overlap vertically.
  Widget twoRows({
    required RegionTraversalPolicy policy,
    required FocusNode upper,
    required double upperLeft,
    required List<FocusNode> lower,
    required List<double> lowerLefts,
  }) {
    Widget node(FocusNode n, double left) => Positioned(
          left: left,
          top: 0,
          child: Focus(
            focusNode: n,
            child: const SizedBox(width: 50, height: 50),
          ),
        );

    return MaterialApp(
      home: FocusTraversalGroup(
        policy: policy,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 600,
              height: 50,
              child: Stack(children: [node(upper, upperLeft)]),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 600,
              height: 50,
              child: Stack(
                children: [
                  for (var i = 0; i < lower.length; i++)
                    node(lower[i], lowerLefts[i]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('LEFT with a candidate only in another row goes to onExit',
      (tester) async {
    final seen = <TraversalDirection>[];
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        seen.add(direction);
        return false;
      },
    );

    final upper = FocusNode(debugLabel: 'upper');
    final lower = FocusNode(debugLabel: 'lower');
    addTearDown(upper.dispose);
    addTearDown(lower.dispose);

    // The upper node sits left of the lower one. Flutter's own search would
    // fall back to it because nothing in the lower row is to the left, which
    // is the row jump a remote viewer reported.
    await tester.pumpWidget(twoRows(
      policy: policy,
      upper: upper,
      upperLeft: 0,
      lower: [lower],
      lowerLefts: [200],
    ));

    lower.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(seen, [TraversalDirection.left]);
    expect(upper.hasFocus, isFalse);
    expect(lower.hasFocus, isTrue);
  });

  testWidgets('RIGHT at the end of a row stays put when onExit declines',
      (tester) async {
    final seen = <TraversalDirection>[];
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        seen.add(direction);
        return false;
      },
    );

    final upper = FocusNode(debugLabel: 'upper');
    final lower = FocusNode(debugLabel: 'lower');
    addTearDown(upper.dispose);
    addTearDown(lower.dispose);

    await tester.pumpWidget(twoRows(
      policy: policy,
      upper: upper,
      upperLeft: 300,
      lower: [lower],
      lowerLefts: [0],
    ));

    lower.requestFocus();
    await tester.pump();

    expect(policy.inDirection(lower, TraversalDirection.right), isFalse);
    await tester.pump();

    expect(seen, [TraversalDirection.right]);
    expect(upper.hasFocus, isFalse);
    expect(lower.hasFocus, isTrue);
  });

  testWidgets(
      'LEFT still moves within the row when another row is further left',
      (tester) async {
    var calls = 0;
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        calls++;
        return true;
      },
    );

    final upper = FocusNode(debugLabel: 'upper');
    final first = FocusNode(debugLabel: 'lower-first');
    final second = FocusNode(debugLabel: 'lower-second');
    addTearDown(upper.dispose);
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    await tester.pumpWidget(twoRows(
      policy: policy,
      upper: upper,
      upperLeft: 0,
      lower: [first, second],
      lowerLefts: [200, 300],
    ));

    second.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();

    expect(first.hasFocus, isTrue);
    expect(calls, 0);
  });

  testWidgets('UP still picks a node that is not directly above',
      (tester) async {
    var calls = 0;
    final policy = RegionTraversalPolicy(
      onExit: (direction) {
        calls++;
        return true;
      },
    );

    final upper = FocusNode(debugLabel: 'upper');
    final lower = FocusNode(debugLabel: 'lower');
    addTearDown(upper.dispose);
    addTearDown(lower.dispose);

    // No horizontal overlap, so this is Flutter's diagonal fallback, which
    // vertical moves keep.
    await tester.pumpWidget(twoRows(
      policy: policy,
      upper: upper,
      upperLeft: 0,
      lower: [lower],
      lowerLefts: [200],
    ));

    lower.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    expect(upper.hasFocus, isTrue);
    expect(calls, 0);
  });

  group('modal popup route guard', () {
    // A single-column list of equal-width rows, the shape `LibrarySortSheet`
    // and `showMediaContextMenu` both build: a `Material` holding a `Column`
    // of same-width focusable rows.
    Widget rowsPage(List<FocusNode> rows) => Material(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final row in rows)
                Focus(
                  focusNode: row,
                  child: const SizedBox(width: 300, height: 48),
                ),
            ],
          ),
        );

    // A region: a FocusTraversalGroup running [policy] around a FocusScope
    // around a nested Navigator, the same shape `AppShell._region` builds
    // around the content column. `onGenerateRoute` hosts the initial page,
    // whose context is captured through [onPageBuilt] so a test can push a
    // real modal route onto this same Navigator afterwards.
    Widget region({
      required RegionTraversalPolicy policy,
      required FocusScopeNode regionScope,
      required GlobalKey<NavigatorState> navigatorKey,
      required void Function(BuildContext) onPageBuilt,
    }) {
      return MaterialApp(
        home: FocusTraversalGroup(
          policy: policy,
          child: FocusScope(
            node: regionScope,
            child: Navigator(
              key: navigatorKey,
              onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (context) {
                  onPageBuilt(context);
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets(
        'LEFT inside a real modal bottom sheet stays put and never reaches '
        'onExit', (tester) async {
      final seen = <TraversalDirection>[];
      final policy = RegionTraversalPolicy(onExit: (direction) {
        seen.add(direction);
        return true;
      });

      final regionScope = FocusScopeNode(debugLabel: 'region');
      final navigatorKey = GlobalKey<NavigatorState>();
      final rowA = FocusNode(debugLabel: 'sheet-row-a');
      final rowB = FocusNode(debugLabel: 'sheet-row-b');
      addTearDown(regionScope.dispose);
      addTearDown(rowA.dispose);
      addTearDown(rowB.dispose);

      late BuildContext pageContext;

      await tester.pumpWidget(region(
        policy: policy,
        regionScope: regionScope,
        navigatorKey: navigatorKey,
        onPageBuilt: (context) => pageContext = context,
      ));

      // The real production shape: `showModalBottomSheet` with the default
      // `useRootNavigator: false`, attaching to this nested Navigator, the
      // one that lives inside the content region's own FocusScope, exactly
      // as it does under `AppShell`.
      unawaited(showModalBottomSheet<void>(
        context: pageContext,
        useRootNavigator: false,
        builder: (context) => rowsPage([rowA, rowB]),
      ));
      await tester.pumpAndSettle();

      rowB.requestFocus();
      await tester.pump();
      expect(rowB.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(seen, isEmpty,
          reason:
              'a press inside the still-open sheet must not reach the region '
              'exit');
      expect(rowB.hasFocus, isTrue);

      // Close the sheet so its route (and the Future awaited above) settles
      // before the test ends; otherwise the still-open sheet's pending
      // navigation work outlives this test's FocusManager and taints the
      // next test.
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    });

    testWidgets(
        'LEFT on the region\'s own page, with no popup route above it, '
        'still calls onExit', (tester) async {
      final seen = <TraversalDirection>[];
      final policy = RegionTraversalPolicy(onExit: (direction) {
        seen.add(direction);
        return true;
      });

      final regionScope = FocusScopeNode(debugLabel: 'region');
      final navigatorKey = GlobalKey<NavigatorState>();
      final rowA = FocusNode(debugLabel: 'page-row-a');
      final rowB = FocusNode(debugLabel: 'page-row-b');
      addTearDown(regionScope.dispose);
      addTearDown(rowA.dispose);
      addTearDown(rowB.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: FocusTraversalGroup(
            policy: policy,
            child: FocusScope(
              node: regionScope,
              child: Navigator(
                key: navigatorKey,
                onGenerateRoute: (settings) => MaterialPageRoute(
                  builder: (context) => rowsPage([rowA, rowB]),
                ),
              ),
            ),
          ),
        ),
      );

      rowB.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(seen, [TraversalDirection.left],
          reason: 'the guard must not disable the ordinary sidebar handoff');
    });
  });
}
