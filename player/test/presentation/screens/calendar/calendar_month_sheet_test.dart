import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/calendar/calendar_month_sheet.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

final today = DateTime(2026, 10, 16);
final windowStart = DateTime(2026, 9, 16);
final windowEnd = DateTime(2027, 1, 14);

Future<List<DateTime?>> _pump(WidgetTester tester,
    {DateTime? initialMonth}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final results = <DateTime?>[];

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => results.add(await showCalendarMonthSheet(
            context,
            windowStart: windowStart,
            windowEnd: windowEnd,
            daySummaries: {
              DateTime(2026, 11, 2): false,
              DateTime(2026, 11, 7): true,
            },
            initialMonth: initialMonth ?? DateTime(2026, 11),
            today: today,
          )),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  testWidgets('opens on the given month with dots by state', (tester) async {
    await _pump(tester);

    expect(find.text('November 2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-sheet-dot-playable-2026-11-07')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('calendar-sheet-dot-scheduled-2026-11-02')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-sheet-dot-playable-2026-11-02')),
        findsNothing);
  });

  testWidgets('tapping a day returns it', (tester) async {
    final results = await _pump(tester);

    await tester
        .tap(find.byKey(const ValueKey('calendar-sheet-day-2026-11-07')));
    await tester.pumpAndSettle();

    expect(results, [DateTime(2026, 11, 7)]);
  });

  testWidgets('days outside the window do nothing', (tester) async {
    final results = await _pump(tester, initialMonth: DateTime(2026, 9));

    await tester
        .tap(find.byKey(const ValueKey('calendar-sheet-day-2026-09-10')));
    await tester.pumpAndSettle();

    expect(results, isEmpty);
    expect(find.text('September 2026'), findsOneWidget);
  });

  testWidgets('arrows page within the window and stop at its ends',
      (tester) async {
    await _pump(tester, initialMonth: DateTime(2026, 9));
    expect(find.byKey(const ValueKey('calendar-sheet-prev')), findsNothing);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byKey(const ValueKey('calendar-sheet-next')));
      await tester.pumpAndSettle();
    }
    expect(find.text('January 2027'), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-sheet-next')), findsNothing);
  });

  testWidgets('the D-pad can pick a day', (tester) async {
    final results = await _pump(tester);

    // The ring sits inside the cell's FocusHighlight, so its nearest Focus
    // ancestor is that highlight's focus node.
    final ring = find.descendant(
      of: find.ancestor(
        of: find.byKey(const ValueKey('calendar-sheet-day-2026-11-07')),
        matching: find.byType(FocusHighlight),
      ),
      matching: find.byKey(FocusHighlight.ringKey),
    );
    Focus.of(tester.element(ring)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(results, [DateTime(2026, 11, 7)]);
  });
}
