import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';
import 'calendar_test_items.dart';

Future<PushedLocations> _pump(
  WidgetTester tester, {
  required List<FakeCapableSource> sources,
  SourceId screenFor = fakeSourceId,
}) =>
    pumpListing(
      tester,
      CalendarScreen(sourceId: screenFor),
      sources: sources,
    );

void main() {
  final today = truncateToDay(DateTime.now());
  FakeCapableSource sourceWith(List<ItemSummary> entries) =>
      FakeCapableSource()..calendarResult = entries;

  testWidgets('opens on the timeline and Today returns to today',
      (tester) async {
    await _pump(
      tester,
      sources: [
        sourceWith([
          for (var i = 1; i <= 15; i++)
            calendarEntry(
                'p$i', DateTime(today.year, today.month, today.day - i),
                playable: true),
          calendarEntry('today', today),
        ])
      ],
    );
    final todayGutter = find.byKey(ValueKey('calendar-day-${isoDate(today)}'));
    expect(find.byKey(const ValueKey('calendar-timeline')), findsOneWidget);
    expect(todayGutter, findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('calendar-timeline')), const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(todayGutter, findsNothing);

    await tester.tap(find.text('Today'));
    await tester.pumpAndSettle();
    expect(todayGutter, findsOneWidget);
  });

  testWidgets('the month button opens the sheet and jumps to the day picked',
      (tester) async {
    final later = DateTime(today.year, today.month, today.day + 45);
    await _pump(
      tester,
      sources: [
        sourceWith([
          calendarEntry('today', today),
          // Enough days between that reaching `later` means scrolling.
          for (var i = 11; i <= 30; i++)
            calendarEntry(
                'f$i', DateTime(today.year, today.month, today.day + i),
                playable: true),
          calendarEntry('later', later),
          // Content below `later` so it can scroll to the top of the
          // viewport. Without it, a `later` that is the 1st of a month stays
          // clamped at the end of the list and the previous month is topmost.
          for (var i = 1; i <= 20; i++)
            calendarEntry(
                'a$i', DateTime(later.year, later.month, later.day + i),
                playable: true),
        ])
      ],
    );
    final todayGutter = find.byKey(ValueKey('calendar-day-${isoDate(today)}'));
    expect(todayGutter, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('calendar-month-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-sheet-title')), findsOneWidget);

    while (find
        .byKey(ValueKey('calendar-sheet-day-${isoDate(later)}'))
        .evaluate()
        .isEmpty) {
      await tester.tap(find.byKey(const ValueKey('calendar-sheet-next')));
      await tester.pumpAndSettle();
    }
    await tester
        .tap(find.byKey(ValueKey('calendar-sheet-day-${isoDate(later)}')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('calendar-sheet-title')), findsNothing);
    expect(
        find.byKey(ValueKey('calendar-day-${isoDate(later)}')), findsOneWidget);
    expect(todayGutter, findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('calendar-month-button')),
        matching: find.text(monthName(later)),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an empty window shows the empty state', (tester) async {
    await _pump(
      tester,
      sources: [sourceWith(const [])],
    );

    expect(find.byKey(const ValueKey('calendar-empty')), findsOneWidget);
  });

  testWidgets('asks the source for the window around today and opens an entry',
      (tester) async {
    final source = sourceWith([calendarEntry('e1', today, playable: true)]);
    final pushed = await _pump(
      tester,
      sources: [source],
    );

    expect(source.calls.single, startsWith('calendar('));

    await tester.tap(find.byKey(const ValueKey('calendar-card-e1')));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/episode/e1');
  });

  testWidgets('an entry with no version has no play button', (tester) async {
    await _pump(
      tester,
      sources: [
        sourceWith([
          calendarEntry('bare', today),
          calendarEntry('ready', today, playable: true),
        ]),
      ],
    );

    expect(find.byKey(const ValueKey('calendar-play-bare')), findsNothing);
    expect(find.byKey(const ValueKey('calendar-play-ready')), findsOneWidget);
  });

  testWidgets('play goes to the source player with the default version',
      (tester) async {
    final entry = calendarEntry('ready', today, playable: true);
    final pushed = await _pump(
      tester,
      sources: [
        sourceWith([entry])
      ],
    );

    await tester.tap(find.byKey(const ValueKey('calendar-play-ready')));
    await tester.pumpAndSettle();

    expect(
      pushed.last,
      sourcePlayerLocation(entry.ref, fileId: 'file-ready', title: entry.title),
    );
  });

  testWidgets('shows the calendar of the source it is scoped to',
      (tester) async {
    final a =
        sourceWith([calendarEntry('a1', today, title: 'First Source Ep')]);
    final b = FakeCapableSource(id: otherSourceId)
      ..calendarResult = [
        calendarEntry('b1', today,
            sourceId: otherSourceId, title: 'Second Source Ep'),
      ];
    await _pump(
      tester,
      sources: [a, b],
      screenFor: otherSourceId,
    );

    expect(find.byKey(const ValueKey('calendar-row-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-row-a1')), findsNothing);
    expect(a.calls, isEmpty);
  });
}
