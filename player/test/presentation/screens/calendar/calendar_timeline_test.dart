import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/calendar/calendar_timeline.dart';

import 'calendar_test_items.dart';

final today = DateTime(2026, 10, 16);

List<DateTime> daysOf(List<TimelineItem> items) => [
      for (final i in items)
        if (i is TimelineDay) i.day,
    ];

void main() {
  group('buildTimeline', () {
    test('one day per date with entries, in server order, empty days skipped',
        () {
      final items = buildTimeline([
        calendarEntry('a', DateTime(2026, 10, 14)),
        calendarEntry('b', today),
        calendarEntry('c', today),
        calendarEntry('d', DateTime(2026, 10, 20)),
      ], today);

      expect(
        daysOf(items),
        [DateTime(2026, 10, 14), today, DateTime(2026, 10, 20)],
      );
      final todayItem =
          items.whereType<TimelineDay>().firstWhere((d) => d.day == today);
      expect(todayItem.entries.map((e) => e.ref.externalId), ['b', 'c']);
    });

    test('inserts today, empty, when nothing airs today', () {
      final items = buildTimeline([
        calendarEntry('a', DateTime(2026, 10, 14)),
        calendarEntry('d', DateTime(2026, 10, 20)),
      ], today);

      expect(
        daysOf(items),
        [DateTime(2026, 10, 14), today, DateTime(2026, 10, 20)],
      );
      expect(
        items
            .whereType<TimelineDay>()
            .firstWhere((d) => d.day == today)
            .entries,
        isEmpty,
      );
    });

    test('puts an empty today last when every entry is past', () {
      final items =
          buildTimeline([calendarEntry('a', DateTime(2026, 10, 1))], today);
      expect(daysOf(items).last, today);
    });

    test('adds a month divider where the month changes, never first', () {
      final items = buildTimeline([
        calendarEntry('a', DateTime(2026, 9, 30)),
        calendarEntry('b', today),
        calendarEntry('c', DateTime(2026, 11, 2)),
      ], today);

      expect(items.first, isA<TimelineDay>());
      final dividers =
          items.whereType<MonthDivider>().map((m) => m.month).toList();
      expect(dividers, [DateTime(2026, 10), DateTime(2026, 11)]);
      expect(
        items[items.indexWhere(
              (i) => i is MonthDivider && i.month == DateTime(2026, 11),
            ) +
            1],
        isA<TimelineDay>().having((d) => d.day, 'day', DateTime(2026, 11, 2)),
      );
    });
  });

  test('daySummaries says whether each day has something playable', () {
    final summaries = daySummaries([
      calendarEntry('a', today, playable: true),
      calendarEntry('b', today),
      calendarEntry('c', DateTime(2026, 10, 20)),
    ]);
    expect(summaries, {today: true, DateTime(2026, 10, 20): false});
  });

  group('TimelineLayout', () {
    test('sizes items from the width at 1x text', () {
      final layout = TimelineLayout(width: 400);
      // 400 - 10 left - 50 gutter - 10 gap - 13 rail - 16 right
      expect(layout.entryWidth, 301);
      expect(layout.cardImageHeight, 150.5);
      expect(layout.cardHeight, 150.5 + 10 + 20 + 2 + 17 + 11);
      expect(layout.cardHeight, 210.5);
      expect(layout.rowHeight, 43);
      expect(layout.gutterHeight, 44);
      expect(layout.monthDividerHeight, 34);
    });

    test('caps the content width on wide screens', () {
      expect(
        TimelineLayout(width: 1600).contentWidth,
        TimelineLayout.maxContentWidth,
      );
    });

    test('scales text-bearing heights with the text scale', () {
      final layout = TimelineLayout(width: 400, textScale: 2);
      // max(36, (20 + 2 + 17) * 2) + 4
      expect(layout.rowHeight, 82);
      expect(layout.gutterHeight, 88);
    });

    test('a day is its padding plus the taller of gutter and entries', () {
      final layout = TimelineLayout(width: 400);
      final oneRow = TimelineDay(today, [calendarEntry('a', today)]);
      final cardAndRow = TimelineDay(today, [
        calendarEntry('a', today, playable: true),
        calendarEntry('b', today),
      ]);
      final emptyToday = TimelineDay(today, const <ItemSummary>[]);

      expect(layout.heightOf(oneRow), 18 + 44);
      expect(layout.heightOf(cardAndRow), 18 + layout.cardHeight + 10 + 43);
      expect(layout.heightOf(emptyToday), 18 + 44);
    });
  });

  group('TimelineGeometry', () {
    final items = buildTimeline([
      calendarEntry('a', DateTime(2026, 10, 14)),
      calendarEntry('b', today, playable: true),
      calendarEntry('c', DateTime(2026, 10, 20)),
      calendarEntry('d', DateTime(2026, 11, 2)),
    ], today);
    final layout = TimelineLayout(width: 400);
    final geometry = TimelineGeometry(items, layout);
    double heightBefore(int index) => [
          for (var i = 0; i < index; i++) layout.heightOf(items[i]),
        ].fold(0.0, (a, b) => a + b);
    int indexOfDay(DateTime day) =>
        items.indexWhere((i) => i is TimelineDay && i.day == day);

    test('offsetOf a day is the height of everything above it', () {
      expect(geometry.offsetOf(DateTime(2026, 10, 14)), 0);
      expect(geometry.offsetOf(today), heightBefore(indexOfDay(today)));
      expect(
        geometry.offsetOf(DateTime(2026, 11, 2)),
        heightBefore(indexOfDay(DateTime(2026, 11, 2))),
      );
    });

    test('an empty day resolves to the next day with entries', () {
      expect(
        geometry.offsetOf(DateTime(2026, 10, 18)),
        geometry.offsetOf(DateTime(2026, 10, 20)),
      );
    });

    test('a day past the last entry resolves to the last day', () {
      expect(
        geometry.offsetOf(DateTime(2027, 1, 10)),
        geometry.offsetOf(DateTime(2026, 11, 2)),
      );
    });

    test('dayAt round-trips offsetOf', () {
      for (final day in daysOf(items)) {
        expect(geometry.dayAt(geometry.offsetOf(day)), day);
      }
    });

    test('dayAt on a month divider names the day below it', () {
      final divider = items.indexWhere(
        (i) => i is MonthDivider && i.month == DateTime(2026, 11),
      );
      expect(geometry.dayAt(heightBefore(divider) + 1), DateTime(2026, 11, 2));
    });

    test('dayAt past the end is the last day', () {
      expect(geometry.dayAt(1e9), DateTime(2026, 11, 2));
    });
  });
}
