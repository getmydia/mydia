import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';

const _leftKey = ValueKey('test-rail-left-fade');
const _rightKey = ValueKey('test-rail-right-fade');

Future<void> _pump(WidgetTester tester, int itemCount) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HorizontalRail(
          itemCount: itemCount,
          height: 120,
          leftFadeKey: _leftKey,
          rightFadeKey: _rightKey,
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('item-$index'),
            width: 200,
            height: 100,
            child: Text('Item $index'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders nothing when there are no items', (tester) async {
    await _pump(tester, 0);

    expect(find.byKey(const ValueKey('item-0')), findsNothing);
    expect(find.byKey(_leftKey), findsNothing);
    expect(find.byKey(_rightKey), findsNothing);
  });

  testWidgets('builds one child per item', (tester) async {
    await _pump(tester, 3);

    expect(find.byKey(const ValueKey('item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('item-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('item-2')), findsOneWidget);
  });

  testWidgets('shows only the right fade before scrolling', (tester) async {
    await _pump(tester, 12);

    expect(find.byKey(_rightKey), findsOneWidget);
    expect(find.byKey(_leftKey), findsNothing);
  });

  testWidgets('shows the left fade once scrolled away from the start',
      (tester) async {
    await _pump(tester, 12);

    await tester.drag(find.byType(ListView), const Offset(-400, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(_leftKey), findsOneWidget);
  });
}
