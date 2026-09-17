import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import 'calendar_dates.dart';

/// The label above one day's entries, shared by both calendar views.
class CalendarDayHeader extends StatelessWidget {
  const CalendarDayHeader({
    super.key,
    required this.day,
    required this.today,
  });

  final DateTime day;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final isToday = isSameDay(day, today);

    return Container(
      height: height,
      // Opaque, or the rows scrolling underneath a pinned header show through.
      color: AppColors.background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Text(
        formatDayHeader(day, today),
        key: ValueKey('calendar-day-${isoDate(day)}'),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: isToday ? AppColors.primary : AppColors.textSecondary,
        ),
      ),
    );
  }
}

/// A [CalendarDayHeader] as a pinned sliver header, for the agenda.
class CalendarDayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const CalendarDayHeaderDelegate({
    required this.day,
    required this.today,
    this.headerKey,
  });

  final DateTime day;
  final DateTime today;

  /// Carried onto the rendered header so `Scrollable.ensureVisible` has an
  /// element to target. Only the today header receives one.
  final Key? headerKey;

  @override
  double get minExtent => CalendarDayHeader.height;

  @override
  double get maxExtent => CalendarDayHeader.height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return CalendarDayHeader(key: headerKey, day: day, today: today);
  }

  @override
  bool shouldRebuild(CalendarDayHeaderDelegate oldDelegate) =>
      oldDelegate.day != day ||
      !isSameDay(oldDelegate.today, today) ||
      oldDelegate.headerKey != headerKey;
}
