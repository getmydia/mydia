// The stock MaterialScrollBehavior leaves PointerDeviceKind.mouse out of
// dragDevices, so grabbing a list with a mouse does nothing. These tests pin
// both halves: that the override adds mouse, and that the stock behavior
// really is what was broken.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/scroll/app_scroll_behavior.dart';

Widget _host({
  required ScrollController controller,
  ScrollBehavior? behavior,
}) {
  return MaterialApp(
    scrollBehavior: behavior,
    home: Scaffold(
      body: ListView.builder(
        controller: controller,
        itemCount: 50,
        itemBuilder: (context, i) => SizedBox(
          height: 100,
          child: Text('row $i'),
        ),
      ),
    ),
  );
}

void main() {
  test('adds mouse without dropping any stock drag device', () {
    const behavior = AppScrollBehavior();

    expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
    expect(
      behavior.dragDevices,
      containsAll(const MaterialScrollBehavior().dragDevices),
    );
  });

  testWidgets('a mouse drag scrolls a list under AppScrollBehavior',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _host(controller: controller, behavior: const AppScrollBehavior()),
    );

    await tester.drag(
      find.text('row 0'),
      const Offset(0, -300),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('the same drag does nothing under the stock behavior',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller: controller));

    await tester.drag(
      find.text('row 0'),
      const Offset(0, -300),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(controller.offset, 0,
        reason: 'this is the bug the override fixes; if this ever passes, '
            'Flutter changed its defaults and the override may be redundant');
  });
}
