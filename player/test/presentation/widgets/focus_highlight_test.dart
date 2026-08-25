// FocusHighlight is what makes the app usable with a D-pad: the ring is the
// only signal telling a viewer holding a remote where they are. A ring that
// nothing responds to is a defect rather than polish, so activation is tested
// alongside the visual.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('paints no ring at rest', (tester) async {
    await tester.pumpWidget(
      _host(
        const FocusHighlight(
          child: SizedBox(width: 40, height: 40),
        ),
      ),
    );

    final decorated = tester.widget<DecoratedBox>(
      find.byKey(FocusHighlight.ringKey),
    );
    expect((decorated.decoration as BoxDecoration).border, isNull);
  });

  testWidgets('paints a ring once focused', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _host(
        FocusHighlight(
          focusNode: node,
          onActivate: () {},
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();

    final decorated = tester.widget<DecoratedBox>(
      find.byKey(FocusHighlight.ringKey),
    );
    expect((decorated.decoration as BoxDecoration).border, isNotNull);
  });

  testWidgets('Enter activates while focused', (tester) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _host(
        FocusHighlight(
          focusNode: node,
          onActivate: () => taps++,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('Space activates while focused', (tester) async {
    var taps = 0;
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _host(
        FocusHighlight(
          focusNode: node,
          onActivate: () => taps++,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets(
      'cannot take focus with no onActivate, so it is never a dead stop',
      (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _host(
        FocusHighlight(
          focusNode: node,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();

    expect(node.hasFocus, isFalse);
  });

  testWidgets('reports focus transitions to onFocusChange', (tester) async {
    final seen = <bool>[];
    final node = FocusNode();
    addTearDown(node.dispose);

    await tester.pumpWidget(
      _host(
        FocusHighlight(
          focusNode: node,
          onActivate: () {},
          onFocusChange: seen.add,
          child: const SizedBox(width: 40, height: 40),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    node.unfocus();
    await tester.pump();

    expect(seen, [true, false]);
  });
}
