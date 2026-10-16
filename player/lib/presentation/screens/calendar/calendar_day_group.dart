import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import 'calendar_card.dart';
import 'calendar_dates.dart';
import 'calendar_row.dart';
import 'calendar_timeline.dart';

/// One day of the timeline: the date in a left gutter, its entries to the
/// right of a thin rail. Exactly [TimelineLayout.heightOf] tall, because the
/// list gives it that extent.
class CalendarDayGroup extends StatelessWidget {
  const CalendarDayGroup({
    super.key,
    required this.item,
    required this.today,
    required this.layout,
  });

  final TimelineDay item;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  final TimelineLayout layout;

  @override
  Widget build(BuildContext context) {
    final isToday = isSameDay(item.day, today);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TimelineLayout.leftPad,
        TimelineLayout.dayPadTop,
        TimelineLayout.rightPad,
        TimelineLayout.dayPadBottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: TimelineLayout.gutterWidth,
            child: _Gutter(day: item.day, today: today),
          ),
          const SizedBox(width: TimelineLayout.gutterGap),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isToday ? AppColors.primary : AppColors.divider,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: TimelineLayout.railPad - 1,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _entries(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _entries() {
    if (item.entries.isEmpty) {
      return [
        SizedBox(
          height: layout.rowHeight,
          child: const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Nothing new today',
              key: ValueKey('calendar-today-empty'),
              style: TextStyle(fontSize: 13, color: AppColors.textDisabled),
            ),
          ),
        ),
      ];
    }

    return [
      for (final (index, entry) in item.entries.indexed) ...[
        if (index > 0) const SizedBox(height: TimelineLayout.entryGap),
        SizedBox(
          key: ValueKey('calendar-entry-${entry.ref.externalId}'),
          height: layout.entryHeight(entry),
          child: entry.isPlayable
              ? CalendarCard(
                  entry: entry,
                  today: today,
                  imageHeight: layout.cardImageHeight,
                )
              : CalendarRow(entry: entry, today: today),
        ),
      ],
    ];
  }
}

class _Gutter extends StatelessWidget {
  const _Gutter({required this.day, required this.today});

  final DateTime day;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final isToday = isSameDay(day, today);
    final isPast = day.isBefore(truncateToDay(today));
    final weekdayColor = isToday ? AppColors.primary : AppColors.textDisabled;
    final numberColor = isToday ? AppColors.primary : AppColors.textPrimary;

    return Opacity(
      key: ValueKey('calendar-day-${isoDate(day)}'),
      opacity: isPast ? 0.55 : 1,
      child: Column(
        children: [
          Text(
            weekdayAbbreviation(day).toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              height: TimelineLayout.weekdayLine / 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: weekdayColor,
            ),
          ),
          Text(
            '${day.day}',
            // One line however wide the glyphs: a wrapped number would be
            // taller than the extent the list gives the group.
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 26,
              height: TimelineLayout.dayNumberLine / 26,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: numberColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// The rule before the first day of a new month.
class CalendarMonthRule extends StatelessWidget {
  const CalendarMonthRule({super.key, required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('calendar-month-${isoDate(month)}'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Text(
            monthName(month).toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              height: TimelineLayout.monthLine / 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: AppColors.textDisabled,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(child: Divider(height: 1, color: AppColors.divider)),
        ],
      ),
    );
  }
}
