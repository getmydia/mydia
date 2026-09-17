import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/screens/calendar/calendar_today_requests.dart';
import 'package:player/presentation/screens/calendar/calendar_week_view.dart';

/// Wed Sep 16 2026. Its window is Aug 17 to Dec 15.
final _today = DateTime(2026, 9, 16);

CalendarEntry _entry(String id, DateTime airDate, {bool playable = false}) =>
    CalendarEntry(
      id: id,
      kind: CalendarEntryKind.episode,
      airDate: airDate,
      title: 'Episode $id',
      seasonNumber: 1,
      episodeNumber: 1,
      mediaItemId: '7',
      mediaItemTitle: 'A Show',
      files: playable
          ? [MediaFile(id: 'file-$id', directPlaySupported: true)]
          : const [],
    );

final _entries = [
  _entry('1', DateTime(2026, 9, 16), playable: true),
  _entry('2', DateTime(2026, 9, 17)),
  _entry('3', DateTime(2026, 9, 23)),
];

Future<CalendarTodayRequests> _pump(
  WidgetTester tester,
  List<CalendarEntry> entries, {
  CalendarTodayRequests? requests,
}) async {
  final todayRequests = requests ?? CalendarTodayRequests();
  if (requests == null) addTearDown(todayRequests.dispose);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: CalendarWeekView(
            entries: entries,
            today: _today,
            scrollTopPadding: 0,
            todayRequests: todayRequests,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return todayRequests;
}

Finder _day(String iso) => find.byKey(ValueKey('calendar-week-day-$iso'));

Finder _header(String iso) => find.byKey(ValueKey('calendar-day-$iso'));

Finder _row(String id) => find.byKey(ValueKey('calendar-entry-$id'));

const _next = ValueKey('calendar-week-next');

void main() {
  group('sameWeekdayIn', () {
    final windowStart = DateTime(2026, 8, 19);
    final windowEnd = DateTime(2026, 12, 15);

    test('keeps the weekday in the new week', () {
      expect(
        sameWeekdayIn(
          DateTime(2026, 9, 21),
          DateTime(2026, 9, 16),
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
        DateTime(2026, 9, 23),
      );
    });

    test('pulls a day before the window forward to its first day', () {
      expect(
        sameWeekdayIn(
          DateTime(2026, 8, 17),
          DateTime(2026, 9, 14),
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
        DateTime(2026, 8, 19),
      );
    });

    test('pulls a day after the window back to its last day', () {
      expect(
        sameWeekdayIn(
          DateTime(2026, 12, 14),
          DateTime(2026, 9, 18),
          windowStart: windowStart,
          windowEnd: windowEnd,
        ),
        DateTime(2026, 12, 15),
      );
    });
  });

  testWidgets('opens on today with its entries', (tester) async {
    await _pump(tester, _entries);

    expect(find.byKey(const ValueKey('calendar-week-view')), findsOneWidget);
    expect(find.text('Sep 14 – 20, 2026'), findsOneWidget);
    expect(find.text('Wed 16 September · Today'), findsOneWidget);
    expect(_row('1'), findsOneWidget);
    expect(_row('2'), findsNothing);
  });

  testWidgets('selecting another day lists that day instead', (tester) async {
    await _pump(tester, _entries);

    await tester.tap(_day('2026-09-17'));
    await tester.pumpAndSettle();

    expect(_header('2026-09-17'), findsOneWidget);
    expect(_row('2'), findsOneWidget);
    expect(_row('1'), findsNothing);
  });

  testWidgets('a day with nothing on it says so', (tester) async {
    await _pump(tester, _entries);

    await tester.tap(_day('2026-09-18'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('calendar-week-empty-day')),
      findsOneWidget,
    );
    expect(find.text('Nothing scheduled this day'), findsOneWidget);
  });

  testWidgets('the next arrow keeps the weekday', (tester) async {
    await _pump(tester, _entries);

    await tester.tap(find.byKey(_next));
    await tester.pumpAndSettle();

    expect(find.text('Sep 21 – 27, 2026'), findsOneWidget);
    expect(_header('2026-09-23'), findsOneWidget);
    expect(_row('3'), findsOneWidget);
  });

  testWidgets('a today request returns to today', (tester) async {
    final requests = await _pump(tester, _entries);

    await tester.tap(find.byKey(_next));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_next));
    await tester.pumpAndSettle();
    await tester.tap(_day('2026-10-02'));
    await tester.pumpAndSettle();

    requests.request();
    await tester.pumpAndSettle();

    expect(find.text('Sep 14 – 20, 2026'), findsOneWidget);
    expect(_header('2026-09-16'), findsOneWidget);
    expect(_row('1'), findsOneWidget);
  });

  testWidgets('new entries keep the selected day', (tester) async {
    final requests = await _pump(tester, _entries);

    await tester.tap(_day('2026-09-17'));
    await tester.pumpAndSettle();

    await _pump(
      tester,
      [..._entries, _entry('4', DateTime(2026, 9, 17))],
      requests: requests,
    );

    expect(_header('2026-09-17'), findsOneWidget);
    expect(_row('2'), findsOneWidget);
    expect(_row('4'), findsOneWidget);
  });
}
