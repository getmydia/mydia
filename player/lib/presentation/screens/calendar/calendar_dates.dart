/// Shared date helpers for the calendar screen.
///
/// The calendar throws away time-of-day at several independent points: to
/// send the window's `start`/`end` to the server, to decide which day
/// section is "today", and to group and compare entries by calendar day.
/// Kept in one file so those points cannot drift into subtly different
/// definitions of "day" from one another. The week helpers live here for the
/// same reason: a week is seven of those days, starting on a Monday.
library;

import '../../../domain/models/calendar_entry.dart';

/// Short weekday names, indexed by `DateTime.weekday - 1` (Monday first).
///
/// `package:intl` is not a dependency of this app, so the calendar's labels
/// are hand-formatted from these const tables rather than pulling in
/// `DateFormat` for a handful of strings.
const List<String> _weekdayAbbreviations = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Full month names, indexed by `DateTime.month - 1`.
const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Zero-padded `yyyy-MM-dd`, the format the calendar's GraphQL query takes
/// for its `start`/`end` date arguments.
String isoDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// [date] with its time-of-day dropped, at local midnight.
DateTime truncateToDay(DateTime date) =>
    DateTime(date.year, date.month, date.day);

/// Whether [a] and [b] fall on the same calendar day, ignoring time-of-day.
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// `Mon` through `Sun` for [day].
String weekdayAbbreviation(DateTime day) =>
    _weekdayAbbreviations[day.weekday - DateTime.monday];

/// Entries grouped into day sections, in the order the server sent them.
///
/// The resolver already orders by air date, then playable first, then title,
/// so this preserves order rather than re-sorting. Days with no entries never
/// appear, which is the whole reason an agenda beats a grid on a small
/// library.
List<MapEntry<DateTime, List<CalendarEntry>>> groupByDay(
  List<CalendarEntry> entries,
) {
  final groups = <DateTime, List<CalendarEntry>>{};

  for (final entry in entries) {
    groups.putIfAbsent(entry.day, () => []).add(entry);
  }

  return groups.entries.toList();
}

/// The label above one day's entries.
String formatDayHeader(DateTime day, DateTime today) {
  final isToday = isSameDay(day, today);

  final sameYear = day.year == today.year;
  final weekday = weekdayAbbreviation(day);
  final month = _monthNames[day.month - 1];

  final formatted = sameYear
      ? '$weekday ${day.day} $month'
      : '$weekday ${day.day} $month ${day.year}';

  return isToday ? '$formatted · Today' : formatted;
}

/// The Monday on or before [day], at local midnight.
///
/// Built by overflowing the day field, as `CalendarController.windowFor`
/// does, rather than subtracting a `Duration`. `DateTime`'s constructor
/// normalizes an out-of-range day by calendar arithmetic, so a week that
/// contains a daylight-saving change still starts at midnight.
DateTime startOfWeek(DateTime day) =>
    DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));

/// The Monday of every week that touches `[start, end]`, oldest first.
///
/// One entry per page of the week strip. The first and last weeks are
/// usually partial. Steps by overflowing the day field for the same
/// daylight-saving reason as [startOfWeek].
List<DateTime> weeksInWindow(DateTime start, DateTime end) {
  final last = startOfWeek(end);
  final weeks = <DateTime>[];

  var week = startOfWeek(start);
  while (!week.isAfter(last)) {
    weeks.add(week);
    week = DateTime(week.year, week.month, week.day + DateTime.daysPerWeek);
  }

  return weeks;
}

/// The week strip's title for the week starting [weekStart].
///
/// `Sep 14 – 20, 2026` inside a month, `Sep 28 – Oct 4, 2026` across one,
/// and `Dec 28, 2026 – Jan 3, 2027` across a year.
String formatWeekLabel(DateTime weekStart) {
  final start = truncateToDay(weekStart);
  final end = DateTime(start.year, start.month, start.day + 6);
  final startMonth = _shortMonthName(start);
  final endMonth = _shortMonthName(end);

  if (start.year != end.year) {
    return '$startMonth ${start.day}, ${start.year} – '
        '$endMonth ${end.day}, ${end.year}';
  }

  if (start.month != end.month) {
    return '$startMonth ${start.day} – $endMonth ${end.day}, ${end.year}';
  }

  return '$startMonth ${start.day} – ${end.day}, ${end.year}';
}

String _shortMonthName(DateTime day) =>
    _monthNames[day.month - 1].substring(0, 3);
