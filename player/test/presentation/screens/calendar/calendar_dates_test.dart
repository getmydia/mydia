import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';

CalendarEntry _entry(String id, DateTime airDate) => CalendarEntry(
      id: id,
      kind: CalendarEntryKind.episode,
      airDate: airDate,
      title: 'Episode $id',
      mediaItemId: '7',
      mediaItemTitle: 'A Show',
    );

void main() {
  group('isoDate', () {
    test('zero-pads single-digit month and day', () {
      expect(isoDate(DateTime(2026, 1, 4)), '2026-01-04');
    });

    test('leaves double-digit month and day alone', () {
      expect(isoDate(DateTime(2026, 11, 25)), '2026-11-25');
    });

    test('ignores the time component', () {
      expect(isoDate(DateTime(2026, 8, 27, 23, 59, 59)), '2026-08-27');
    });
  });

  group('truncateToDay', () {
    test('drops the time component', () {
      expect(
          truncateToDay(DateTime(2026, 8, 27, 14, 30)), DateTime(2026, 8, 27));
    });

    test('is a no-op on a value that already has no time component', () {
      final day = DateTime(2026, 8, 27);
      expect(truncateToDay(day), day);
    });
  });

  group('isSameDay', () {
    test('true for the same day at different times', () {
      expect(
        isSameDay(DateTime(2026, 8, 27, 1), DateTime(2026, 8, 27, 23)),
        isTrue,
      );
    });

    test('false for a different day', () {
      expect(isSameDay(DateTime(2026, 8, 27), DateTime(2026, 8, 28)), isFalse);
    });

    test('false for the same month/day in a different year', () {
      expect(isSameDay(DateTime(2026, 8, 27), DateTime(2027, 8, 27)), isFalse);
    });
  });

  group('weekdayAbbreviation', () {
    test('names Monday and Sunday', () {
      expect(weekdayAbbreviation(DateTime(2026, 9, 14)), 'Mon');
      expect(weekdayAbbreviation(DateTime(2026, 9, 20)), 'Sun');
    });
  });

  group('groupByDay', () {
    test('groups entries under their date, preserving server order', () {
      final grouped = groupByDay([
        _entry('1', DateTime(2026, 8, 20)),
        _entry('2', DateTime(2026, 8, 20)),
        _entry('3', DateTime(2026, 8, 22)),
      ]);

      expect(grouped.length, 2);
      expect(grouped.first.key, DateTime(2026, 8, 20));
      expect(grouped.first.value.map((e) => e.id).toList(), ['1', '2']);
      expect(grouped.last.key, DateTime(2026, 8, 22));
    });

    test('emits no group for a day with no entries', () {
      final grouped = groupByDay([
        _entry('1', DateTime(2026, 8, 20)),
        _entry('2', DateTime(2026, 8, 25)),
      ]);

      expect(grouped.map((g) => g.key).toList(), [
        DateTime(2026, 8, 20),
        DateTime(2026, 8, 25),
      ]);
    });

    test('ignores a time component when deciding the day', () {
      final grouped = groupByDay([
        _entry('1', DateTime(2026, 8, 20, 9)),
        _entry('2', DateTime(2026, 8, 20, 21)),
      ]);

      expect(grouped.length, 1);
    });

    test('returns nothing for an empty list', () {
      expect(groupByDay(const []), isEmpty);
    });
  });

  group('formatDayHeader', () {
    test('marks today', () {
      expect(
        formatDayHeader(DateTime(2026, 8, 27), DateTime(2026, 8, 27)),
        'Thu 27 August · Today',
      );
    });

    test('omits the year inside the current year', () {
      expect(
        formatDayHeader(DateTime(2026, 8, 20), DateTime(2026, 8, 27)),
        'Thu 20 August',
      );
    });

    test('includes the year outside the current year', () {
      expect(
        formatDayHeader(DateTime(2027, 1, 4), DateTime(2026, 8, 27)),
        'Mon 4 January 2027',
      );
    });
  });

  group('startOfWeek', () {
    test('returns a Monday unchanged', () {
      expect(startOfWeek(DateTime(2026, 9, 14)), DateTime(2026, 9, 14));
    });

    test('walks a mid-week day back to Monday and drops the time', () {
      expect(
        startOfWeek(DateTime(2026, 9, 16, 15, 30)),
        DateTime(2026, 9, 14),
      );
    });

    test('treats Sunday as the end of the week, not the start', () {
      expect(startOfWeek(DateTime(2026, 9, 20)), DateTime(2026, 9, 14));
    });

    test('crosses a month boundary', () {
      expect(startOfWeek(DateTime(2026, 10, 1)), DateTime(2026, 9, 28));
    });

    test('lands on midnight across a daylight-saving change', () {
      // Nov 1 2026 is the US fall-back Sunday and Oct 25 the EU one. Only a
      // DST-observing timezone can fail this, which is the point: a
      // Duration-based subtraction is off by an hour there.
      final monday = startOfWeek(DateTime(2026, 11, 1));
      expect(monday, DateTime(2026, 10, 26));
      expect(monday.hour, 0);
      expect(startOfWeek(DateTime(2026, 10, 25)), DateTime(2026, 10, 19));
    });
  });

  group('weeksInWindow', () {
    test('covers the calendar window a day in September loads', () {
      // CalendarController.windowFor(Sep 16 2026) is Aug 17 to Dec 15.
      final weeks =
          weeksInWindow(DateTime(2026, 8, 17), DateTime(2026, 12, 15));

      expect(weeks.length, 18);
      expect(weeks.first, DateTime(2026, 8, 17));
      expect(weeks.last, DateTime(2026, 12, 14));
    });

    test('includes the partial weeks at either end', () {
      expect(
        weeksInWindow(DateTime(2026, 9, 16), DateTime(2026, 9, 27)),
        [DateTime(2026, 9, 14), DateTime(2026, 9, 21)],
      );
    });

    test('gives one week for a one-day window', () {
      expect(
        weeksInWindow(DateTime(2026, 9, 16), DateTime(2026, 9, 16)),
        [DateTime(2026, 9, 14)],
      );
    });

    test('keeps every Monday at midnight across a daylight-saving change', () {
      final weeks =
          weeksInWindow(DateTime(2026, 10, 19), DateTime(2026, 11, 2));

      expect(weeks, [
        DateTime(2026, 10, 19),
        DateTime(2026, 10, 26),
        DateTime(2026, 11, 2),
      ]);
      expect(weeks.every((week) => week.hour == 0), isTrue);
    });
  });

  group('formatWeekLabel', () {
    test('names the month once inside a month', () {
      expect(formatWeekLabel(DateTime(2026, 9, 14)), 'Sep 14 – 20, 2026');
    });

    test('names both months across a month boundary', () {
      expect(formatWeekLabel(DateTime(2026, 9, 28)), 'Sep 28 – Oct 4, 2026');
    });

    test('names both years across a year boundary', () {
      expect(
        formatWeekLabel(DateTime(2026, 12, 28)),
        'Dec 28, 2026 – Jan 3, 2027',
      );
    });
  });
}
