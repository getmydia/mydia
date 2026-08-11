import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'text_decoration.dart';

void main() {
  testWidgets('passes when nothing carries a decoration', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('plain'))),
    );

    expectNoDebugTextDecorations(tester);
  });

  testWidgets('catches a decoration on the root span', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text(
            'underlined',
            style: TextStyle(decoration: TextDecoration.underline),
          ),
        ),
      ),
    );

    expect(
      () => expectNoDebugTextDecorations(tester),
      throwsA(isA<TestFailure>()),
    );
  });

  testWidgets('catches a decoration on a descendant span', (tester) async {
    // The root span holds no text and no style, so a root-only check waves this
    // through. This is the shape `Text.rich` produces and the reason the helper
    // walks the whole tree.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: 'clean '),
                TextSpan(
                  text: 'underlined',
                  style: TextStyle(decoration: TextDecoration.underline),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      () => expectNoDebugTextDecorations(tester),
      throwsA(isA<TestFailure>()),
    );
  });
}
