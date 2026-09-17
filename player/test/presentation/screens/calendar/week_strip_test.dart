import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/screens/calendar/week_strip.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

class _Recorder {
  final List<DateTime> selected = [];
  final List<int> pages = [];
}

/// Two weeks, Sep 14 to Sep 27 2026, today Wed Sep 16, selected Sep 16.
Future<_Recorder> _pump(
  WidgetTester tester, {
  DateTime? windowStart,
  Map<DateTime, bool> daySummaries = const {},
}) async {
  final recorder = _Recorder();
  final controller = PageController();
  addTearDown(controller.dispose);
  var page = 0;

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => WeekStrip(
            weeks: [DateTime(2026, 9, 14), DateTime(2026, 9, 21)],
            pageController: controller,
            currentPage: page,
            selectedDay: DateTime(2026, 9, 16),
            today: DateTime(2026, 9, 16),
            windowStart: windowStart ?? DateTime(2026, 9, 14),
            windowEnd: DateTime(2026, 9, 27),
            daySummaries: daySummaries,
            onSelectDay: recorder.selected.add,
            onPageChanged: (next) {
              recorder.pages.add(next);
              setState(() => page = next);
            },
          ),
        ),
      ),
    ),
  );

  return recorder;
}

Finder _day(String iso) => find.byKey(ValueKey('calendar-week-day-$iso'));

Finder _dot(String iso) => find.byKey(ValueKey('calendar-week-dot-$iso'));

/// The focus ring inside the cell's own [FocusHighlight]. Its nearest
/// `Focus` ancestor is that highlight's focus node.
Finder _ring(String iso) => find.descendant(
      of: find.ancestor(of: _day(iso), matching: find.byType(FocusHighlight)),
      matching: find.byKey(FocusHighlight.ringKey),
    );

Color? _fill(WidgetTester tester, Finder finder) =>
    (tester.widget<Container>(finder).decoration as BoxDecoration?)?.color;

void main() {
  testWidgets('shows the seven days of the current week', (tester) async {
    await _pump(tester);

    for (var day = 14; day <= 20; day++) {
      expect(_day('2026-09-$day'), findsOneWidget);
    }
    expect(_day('2026-09-21'), findsNothing);
    expect(find.text('Sep 14 – 20, 2026'), findsOneWidget);
  });

  testWidgets('fills only the selected day', (tester) async {
    await _pump(tester);

    expect(_fill(tester, _day('2026-09-16')), WeekStrip.selectedFill);
    expect(_fill(tester, _day('2026-09-17')), isNull);
  });

  testWidgets('dots days with entries, in primary when one is playable',
      (tester) async {
    await _pump(
      tester,
      daySummaries: {
        DateTime(2026, 9, 14): true,
        DateTime(2026, 9, 17): false,
      },
    );

    expect(_fill(tester, _dot('2026-09-14')), AppColors.primary);
    expect(_fill(tester, _dot('2026-09-17')), AppColors.textDisabled);
    expect(_dot('2026-09-15'), findsNothing);
  });

  testWidgets('tapping a day reports it', (tester) async {
    final recorder = await _pump(tester);

    await tester.tap(_day('2026-09-18'));
    await tester.pump();

    expect(recorder.selected, [DateTime(2026, 9, 18)]);
  });

  testWidgets('a day outside the window ignores taps and takes no focus',
      (tester) async {
    final recorder = await _pump(tester, windowStart: DateTime(2026, 9, 16));

    await tester.tap(_day('2026-09-15'));
    await tester.pump();

    expect(recorder.selected, isEmpty);
    expect(
        Focus.of(tester.element(_ring('2026-09-15'))).canRequestFocus, isFalse);
  });

  testWidgets('an activation key on a focused day selects it', (tester) async {
    final recorder = await _pump(tester);

    Focus.of(tester.element(_ring('2026-09-17'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(recorder.selected, [DateTime(2026, 9, 17)]);
  });

  testWidgets('arrows page the strip and hide at either end', (tester) async {
    final recorder = await _pump(tester);
    const prev = ValueKey('calendar-week-prev');
    const next = ValueKey('calendar-week-next');

    expect(find.byKey(prev), findsNothing);
    expect(find.byKey(next), findsOneWidget);

    await tester.tap(find.byKey(next));
    await tester.pumpAndSettle();

    expect(recorder.pages, [1]);
    expect(find.text('Sep 21 – 27, 2026'), findsOneWidget);
    expect(find.byKey(prev), findsOneWidget);
    expect(find.byKey(next), findsNothing);
  });

  testWidgets('fits a narrow phone without overflowing', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pump(tester);

    expect(tester.takeException(), isNull);
  });
}
