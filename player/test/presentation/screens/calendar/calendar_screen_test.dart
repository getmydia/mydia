import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_screen.dart';

CalendarEntry _entry(String id, DateTime airDate) => CalendarEntry(
      id: id,
      kind: CalendarEntryKind.episode,
      airDate: airDate,
      title: 'Episode $id',
      mediaItemId: '7',
      mediaItemTitle: 'A Show',
    );

void main() {
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
}
