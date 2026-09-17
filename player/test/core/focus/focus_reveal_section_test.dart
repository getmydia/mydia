// Off the television tier the section must be invisible to the focus tree,
// so phone, desktop and web traversal stay exactly as they were.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_reveal_section.dart';
import 'package:player/core/player/input_capabilities.dart';

void main() {
  // `testWidgets` takes only a bool `skip`; `group` accepts a reason, which is
  // why the television suites skip at group level too.
  group('FocusRevealSection off the television tier', () {
    testWidgets('adds no Focus widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FocusRevealSection(child: SizedBox(width: 10, height: 10)),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(FocusRevealSection),
          matching: find.byType(Focus),
        ),
        findsNothing,
      );
    });
  },
      skip: InputCapabilities.directionalPrimary
          ? 'runs only off the television tier'
          : false);
}
