import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/presentation/widgets/browse_grid.dart';

Future<void> pumpGrid(
  WidgetTester tester, {
  required Size size,
  double scrollTopPadding = 120,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BrowseGrid(
          itemCount: 24,
          scrollTopPadding: scrollTopPadding,
          itemBuilder: (context, index) => SizedBox(
            key: ValueKey('item-$index'),
            child: Text('Item $index'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('libraryCrossAxisCount', () {
    // The exact table the library grid has always used. Moving the function
    // between files must not change a single boundary.
    test('matches the established column table', () {
      expect(libraryCrossAxisCount(1500), 8);
      expect(libraryCrossAxisCount(1300), 7);
      expect(libraryCrossAxisCount(1100), 6);
      expect(libraryCrossAxisCount(900), 5);
      expect(libraryCrossAxisCount(700), 4);
      expect(libraryCrossAxisCount(500), 3);
      expect(libraryCrossAxisCount(300), 2);
    });
  });

  testWidgets('reserves the caller scrollTopPadding above the first item',
      (tester) async {
    await pumpGrid(tester, size: const Size(1200, 900));

    final grid = tester.widget<GridView>(find.byType(GridView));
    final padding = grid.padding! as EdgeInsets;

    expect(padding.top, 120);
  });

  testWidgets('uses Breakpoints gutters rather than a hardcoded value',
      (tester) async {
    await pumpGrid(tester, size: const Size(1200, 900));

    final grid = tester.widget<GridView>(find.byType(GridView));
    final padding = grid.padding! as EdgeInsets;

    // 1200 is at or above the desktop breakpoint, so 32.
    expect(padding.left, 32);
    expect(padding.right, 32);
  });

  testWidgets('lays out the app-wide column count for its width',
      (tester) async {
    await pumpGrid(tester, size: const Size(1200, 900));

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;

    // 1200 wide minus 32 gutters each side leaves 1136 for the grid itself.
    expect(delegate.crossAxisCount, libraryCrossAxisCount(1136));
    expect(delegate.childAspectRatio, 0.58);
  });
}
