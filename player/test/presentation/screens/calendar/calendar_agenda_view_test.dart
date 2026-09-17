import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_agenda_view.dart';
import 'package:player/presentation/screens/calendar/calendar_today_requests.dart';

final _today = DateTime(2026, 8, 27);

const _agenda = ValueKey('calendar-agenda-view');
const _todayHeader = ValueKey('calendar-day-2026-08-27');

CalendarEntry _entry(String id, DateTime airDate) => CalendarEntry(
      id: id,
      kind: CalendarEntryKind.episode,
      airDate: airDate,
      title: 'Episode $id',
      seasonNumber: 1,
      episodeNumber: 1,
      mediaItemId: '7',
      mediaItemTitle: 'A Show',
    );

/// One entry a day from Aug 1 to Aug 20, then Aug 27 to Sep 10, so today's
/// section starts well below the fold and has enough days after it to reach
/// the top.
List<CalendarEntry> _entries() => [
      for (var day = 1; day <= 20; day++)
        _entry('past-$day', DateTime(2026, 8, day)),
      for (var offset = 0; offset <= 14; offset++)
        _entry('next-$offset', DateTime(2026, 8, 27 + offset)),
    ];

Future<CalendarTodayRequests> _pump(WidgetTester tester) async {
  final requests = CalendarTodayRequests();
  addTearDown(requests.dispose);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: CalendarAgendaView(
            entries: _entries(),
            today: _today,
            scrollTopPadding: 0,
            todayRequests: requests,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return requests;
}

void main() {
  group('indexOfToday', () {
    test('finds the group for today when today has entries', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 27), DateTime(2026, 8, 30)],
        DateTime(2026, 8, 27),
      );

      expect(index, 1);
    });

    test('falls forward to the next day when today has no entries', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 30)],
        DateTime(2026, 8, 27),
      );

      expect(index, 1);
    });

    test('is null when every day is in the past', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 20), DateTime(2026, 8, 21)],
        DateTime(2026, 8, 27),
      );

      expect(index, isNull);
    });

    test('ignores the time of day on the reference date', () {
      final index = indexOfToday(
        [DateTime(2026, 8, 27)],
        DateTime(2026, 8, 27, 23, 30),
      );

      expect(index, 0);
    });

    test('is null for an empty list', () {
      expect(indexOfToday(const [], DateTime(2026, 8, 27)), isNull);
    });
  });

  testWidgets('opens with today at the top', (tester) async {
    await _pump(tester);

    expect(find.byKey(_todayHeader), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(_todayHeader)).dy, lessThan(38));
  });

  testWidgets('a today request scrolls back to today', (tester) async {
    final requests = await _pump(tester);

    await tester.drag(find.byKey(_agenda), const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.byKey(_todayHeader), findsNothing);

    requests.request();
    await tester.pumpAndSettle();

    expect(find.byKey(_todayHeader), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(_todayHeader)).dy, lessThan(38));
  });

  testWidgets('ends with the end-of-window note', (tester) async {
    await _pump(tester);

    await tester.drag(find.byKey(_agenda), const Offset(0, -5000));
    await tester.pumpAndSettle();

    expect(
      find.text('That is everything scheduled in the next 90 days.'),
      findsOneWidget,
    );
  });
}
