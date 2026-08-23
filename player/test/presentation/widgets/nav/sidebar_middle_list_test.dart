import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/widgets/nav/sidebar_middle_list.dart';

List<SidebarEditRow> _rows({Set<String> hidden = const {}}) {
  return SidebarLayout.defaults
      .reconcileForEditing(downloadSupported: true)
      .map(
        (row) => SidebarEditRow(
          destination: row.destination,
          hidden: hidden.contains(row.destination.id),
        ),
      )
      .toList();
}

Future<void> _pumpList(
  WidgetTester tester, {
  required bool editing,
  List<SidebarEditRow>? rows,
  void Function(int, int)? onReorder,
  void Function(String)? onRestore,
  double height = 220,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: height,
          child: SidebarMiddleList(
            editing: editing,
            rows: rows ?? _rows(),
            buildRow: (row, {editingTrailing}) => SizedBox(
              height: 46,
              child: Row(
                children: [
                  Expanded(child: Text(row.destination.label)),
                  if (editingTrailing != null) editingTrailing,
                ],
              ),
            ),
            onReorder: onReorder ?? (_, __) {},
            onRestore: onRestore ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('normal mode scrolls when a row is dragged', (tester) async {
    // The bug this whole change exists for. A ReorderableDragStartListener uses
    // an immediate drag recognizer, so wrapping every row in one meant a touch
    // drag started a reorder and the list never scrolled.
    await _pumpList(tester, editing: false);

    final scrollable = find.descendant(
      of: find.byType(SidebarMiddleList),
      matching: find.byType(Scrollable),
    );
    final before = tester.state<ScrollableState>(scrollable).position.pixels;

    await tester.drag(find.text('Home'), const Offset(0, -140));
    await tester.pumpAndSettle();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(after, greaterThan(before));
  });

  testWidgets('normal mode builds no drag machinery at all', (tester) async {
    await _pumpList(tester, editing: false);

    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byType(ReorderableListView), findsNothing);
  });

  testWidgets('normal mode omits hidden rows', (tester) async {
    await _pumpList(
      tester,
      editing: false,
      rows: _rows(hidden: {'movies'}),
      height: 900,
    );

    expect(find.text('Movies'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('edit mode shows hidden rows and builds grips', (tester) async {
    await _pumpList(
      tester,
      editing: true,
      rows: _rows(hidden: {'movies'}),
      height: 900,
    );

    expect(find.text('Movies'), findsOneWidget);
    expect(find.byType(ReorderableDragStartListener), findsWidgets);
  });

  testWidgets('edit mode gives a hidden row a restore control, not a grip',
      (tester) async {
    var restored = <String>[];
    await _pumpList(
      tester,
      editing: true,
      rows: _rows(hidden: {'movies'}),
      onRestore: restored.add,
      height: 900,
    );

    await tester.tap(find.byTooltip('Restore Movies'));
    await tester.pumpAndSettle();

    expect(restored, ['movies']);
  });

  testWidgets(
      'edit mode passes the raw ReorderableListView indices straight '
      'through, unmodified', (tester) async {
    // `_rows()` (no hidden ids) puts Home at index 0, Continue Watching at
    // 1, Movies at 2 — see SidebarLayout.defaults' builtin ordering.
    final captured = <(int, int)>[];
    await _pumpList(
      tester,
      editing: true,
      onReorder: (oldIndex, newIndex) => captured.add((oldIndex, newIndex)),
      height: 900,
    );

    // Drag Home's grip down until the drag proxy settles past Movies (row
    // index 2). Every row occupies a fixed 48px slot (46px content from
    // `_pumpList`'s `buildRow` plus this widget's own 2px bottom padding),
    // so rows sit at [0,48), [48,96), [96,144)... Dragging down by 84px
    // puts the dragged proxy's trailing edge at 132px, inside Movies'
    // ending half (its midpoint-to-end span is 120-144px). Per
    // `_dragUpdateItems` in the Flutter SDK's
    // `packages/flutter/lib/src/widgets/reorderable_list.dart`, landing in
    // an item's ending half sets `newIndex = item.index + 1`, i.e. 3 —
    // NOT 2. That "+1" is Flutter's documented pre-removal semantics:
    // ReorderableListView reports newIndex as the insertion point in the
    // list *before* the dragged row is removed, one past where the row
    // actually lands once removal happens. `SidebarLayout
    // .orderAfterReorder` performs exactly that one adjustment itself.
    //
    // If this widget "helpfully" pre-adjusted newIndex too (reintroducing
    // a second `-= 1`), this test would observe (0, 2) here instead of
    // (0, 3) — precisely the off-by-one-on-downward-drags failure mode
    // the brief warns about by name.
    final grip = find.descendant(
      of: find.byKey(const ValueKey('home')),
      matching: find.byType(ReorderableDragStartListener),
    );
    final gesture = await tester.startGesture(tester.getCenter(grip));
    await tester.pump(kPressTimeout);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 21));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(captured, [(0, 3)]);
  });
}
