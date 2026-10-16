import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_dates.dart';

import 'calendar_test_items.dart';

ItemSummary _entry(String id, DateTime airDate) =>
    calendarEntry(id, airDate, title: 'Episode $id');

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
      expect(grouped.first.value.map((e) => e.ref.externalId).toList(),
          ['1', '2']);
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

    test('leaves out an entry the server gave no air date', () {
      final undated = ItemSummary(
        ref: _entry('x', DateTime(2026, 8, 20)).ref,
        title: 'Undated',
      );

      expect(groupByDay([undated]), isEmpty);
      expect(undated.day, isNull);
    });
  });

  group('calendar text', () {
    test('an episode is titled by its show and numbered', () {
      final e = calendarEntry(
        '1',
        DateTime(2026, 10, 16),
        title: 'The Tide Ledger',
        season: 2,
        episode: 5,
      );
      expect(e.calendarTitle, 'A Show');
      expect(e.calendarNumbering, 'S02E05');
      expect(e.calendarSubtitle, 'S02E05 · The Tide Ledger');
    });

    test('a movie is titled by itself and labelled Movie', () {
      final m = calendarEntry(
        '2',
        DateTime(2026, 10, 16),
        kind: ItemKind.movie,
        title: 'Brasswork',
      );
      expect(m.calendarTitle, 'Brasswork');
      expect(m.calendarNumbering, 'Movie');
      expect(m.calendarSubtitle, 'Movie');
    });
  });

  group('month helpers', () {
    test('formatMonth omits the current year and names another', () {
      final today = DateTime(2026, 10, 16);
      expect(formatMonth(DateTime(2026, 11), today), 'November');
      expect(formatMonth(DateTime(2027, 1), today), 'January 2027');
    });

    test('formatMonthYear always names the year', () {
      expect(formatMonthYear(DateTime(2026, 11)), 'November 2026');
    });

    test('monthsInWindow lists every month the window touches', () {
      expect(monthsInWindow(DateTime(2026, 9, 16), DateTime(2027, 1, 14)), [
        DateTime(2026, 9),
        DateTime(2026, 10),
        DateTime(2026, 11),
        DateTime(2026, 12),
        DateTime(2027, 1),
      ]);
    });
  });
}
