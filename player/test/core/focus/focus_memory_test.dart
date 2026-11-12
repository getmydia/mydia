// Off the television tier, focus memory must be invisible: no extra `Focus`
// widgets, so phones, tablets, desktop and the web keep today's traversal,
// Tab order included. The TV behaviour is pinned in focus_memory_tv_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/player/input_capabilities.dart';

void main() {
  testWidgets(
    'FocusMemoryRegion and FocusMemoryItem add no Focus widgets off TV',
    (tester) async {
      Widget cards({required bool wrapped}) => MaterialApp(
            home: Row(
              children: [
                for (var i = 0; i < 3; i++)
                  wrapped
                      ? FocusMemoryItem(
                          id: 'card-$i',
                          index: i,
                          child: Focus(
                            debugLabel: 'card-$i',
                            child: const SizedBox(width: 100, height: 100),
                          ),
                        )
                      : Focus(
                          debugLabel: 'card-$i',
                          child: const SizedBox(width: 100, height: 100),
                        ),
              ],
            ),
          );

      await tester.pumpWidget(cards(wrapped: false));
      final bare = find.byType(Focus).evaluate().length;

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        FocusMemoryRegion(child: cards(wrapped: true)),
      );
      expect(find.byType(Focus).evaluate().length, bare);
    },
    // Passthrough only applies off the television tier.
    skip: InputCapabilities.directionalPrimary,
  );

  testWidgets(
    'FocusMemoryColumn adds no Focus widget off TV',
    (tester) async {
      const page = SizedBox(width: 100, height: 100);
      await tester.pumpWidget(const MaterialApp(home: page));
      final bare = find.byType(Focus).evaluate().length;

      await tester.pumpWidget(
        const MaterialApp(home: FocusMemoryColumn(child: page)),
      );

      expect(find.byType(Focus).evaluate().length, bare);
    },
    skip: InputCapabilities.directionalPrimary,
  );
}
