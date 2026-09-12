// The region boundary's hand-off. Confinement itself is a property of the
// FocusScope the caller installs, so it is asserted by the shell test in
// tv_sidebar_traversal_tv_test.dart; what is asserted here is the contract on
// its own — that a direction the region cannot satisfy is offered to onExit,
// and that handled directions are not re-dispatched.

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
}
