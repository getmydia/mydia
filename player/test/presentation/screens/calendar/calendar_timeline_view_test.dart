import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/util/iso_date.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_jump_requests.dart';
import 'package:player/presentation/screens/calendar/calendar_timeline_view.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'calendar_test_items.dart';

final today = DateTime(2026, 10, 16);

List<ItemSummary> _window() => [
      // Oldest first: the server sends entries in air date order.
      for (var i = 20; i >= 1; i--)
        calendarEntry('past$i', DateTime(2026, 10, 16 - i), playable: true),
      calendarEntry('now', today, playable: true),
      calendarEntry('soon', DateTime(2026, 10, 17)),
      calendarEntry('far', DateTime(2026, 12, 15)),
      // Trailing days so the far day is not within a screen of the end, where
      // the list would clamp before it reached the top.
      for (var i = 1; i <= 15; i++)
        calendarEntry('tail$i', DateTime(2026, 12, 15 + i)),
    ];

Future<({CalendarJumpRequests jumps, List<DateTime> months})> _pump(
  WidgetTester tester,
  List<ItemSummary> entries,
) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final jumps = CalendarJumpRequests();
  addTearDown(jumps.dispose);
  final months = <DateTime>[];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sourceArtworkProvider.overrideWith((ref, key) async => null)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CalendarTimelineView(
            entries: entries,
            today: today,
            scrollTopPadding: 0,
            jumpRequests: jumps,
            onMonthChanged: months.add,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (jumps: jumps, months: months);
}

double _top(WidgetTester tester, DateTime day) =>
    tester.getTopLeft(find.byKey(ValueKey('calendar-day-${isoDate(day)}'))).dy;

void main() {
  testWidgets('opens with today at the top, past days above', (tester) async {
    await _pump(tester, _window());

    expect(_top(tester, today), closeTo(12, 1)); // dayPadTop
    expect(find.byKey(const ValueKey('calendar-day-2026-10-15')), findsNothing);
  });

  testWidgets('playable entries are cards, others rows', (tester) async {
    await _pump(tester, _window());

    expect(find.byKey(const ValueKey('calendar-card-now')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-row-soon')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('calendar-upcoming-soon')), findsOneWidget);
  });

  testWidgets('an empty today still has a row', (tester) async {
    await _pump(tester, [calendarEntry('soon', DateTime(2026, 10, 17))]);

    expect(find.byKey(const ValueKey('calendar-today-empty')), findsOneWidget);
    expect(find.text('Nothing new today'), findsOneWidget);
  });

  testWidgets('a jump to a far day lands it at the top', (tester) async {
    final (:jumps, :months) = await _pump(tester, _window());

    jumps.request(DateTime(2026, 12, 15));
    await tester.pumpAndSettle();

    expect(_top(tester, DateTime(2026, 12, 15)), closeTo(12, 1));
    expect(months.last, DateTime(2026, 12));
  });

  testWidgets('a jump to an empty day lands on the next day with entries',
      (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());

    jumps.request(DateTime(2026, 11, 1));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('calendar-day-2026-12-15')), findsOneWidget);
  });

  testWidgets('a jump back to today returns there after scrolling',
      (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());

    await tester.drag(
        find.byKey(const ValueKey('calendar-timeline')), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(
        find.byKey(ValueKey('calendar-day-${isoDate(today)}')), findsNothing);

    jumps.request(today);
    await tester.pumpAndSettle();
    expect(_top(tester, today), closeTo(12, 1));
  });

  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(
        of: find.byKey(const ValueKey('calendar-timeline')),
        matching: find.byType(Scrollable),
      ))
      .position;

  testWidgets('a jump to the last day lands at the true end', (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());

    jumps.request(DateTime(2026, 12, 30));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('calendar-day-2026-12-30')), findsOneWidget);
    expect(position(tester).pixels, position(tester).maxScrollExtent);
  });

  testWidgets('a jump back to an earlier day lands it at the top',
      (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());

    jumps.request(DateTime(2026, 12, 15));
    await tester.pumpAndSettle();
    jumps.request(DateTime(2026, 10, 10));
    await tester.pumpAndSettle();

    expect(_top(tester, DateTime(2026, 10, 10)), closeTo(12, 1));
  });

  testWidgets('overlapping jumps end at the last one requested',
      (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());

    jumps.request(DateTime(2026, 12, 30));
    await tester.pump(const Duration(milliseconds: 50));
    jumps.request(DateTime(2026, 10, 10));
    await tester.pumpAndSettle();

    expect(_top(tester, DateTime(2026, 10, 10)), closeTo(12, 1));
  });

  testWidgets('reports the month at the top as it changes', (tester) async {
    final (jumps: _, :months) = await _pump(tester, _window());
    expect(months, [DateTime(2026, 10)]);

    await tester.drag(
        find.byKey(const ValueKey('calendar-timeline')), const Offset(0, 6000));
    await tester.pumpAndSettle();
    expect(months.last, DateTime(2026, 9));
  });

  testWidgets('a month rule separates months', (tester) async {
    final (:jumps, months: _) = await _pump(tester, _window());
    jumps.request(DateTime(2026, 12, 15));
    await tester.pumpAndSettle();
    await tester.drag(
        find.byKey(const ValueKey('calendar-timeline')), const Offset(0, 60));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('calendar-month-2026-12-01')),
        findsOneWidget);
  });
}
