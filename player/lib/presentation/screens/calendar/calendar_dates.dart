/// Shared date helpers for the calendar screen.
///
/// The calendar throws away time-of-day at several independent points: to
/// send the window's `start`/`end` to the server, to decide which day
/// section is "today", and to group and compare entries by calendar day.
/// Kept in one file so those points cannot drift into subtly different
/// definitions of "day" from one another. The month helpers live here for the
/// same reason: a month is the days sharing a first.
library;

import '../../../domain/sources/item.dart';

export '../../../core/util/iso_date.dart';

/// What the calendar reads off a listing entry.
extension CalendarItem on ItemSummary {
  /// The day it airs, with no time component, for grouping. Null for an
  /// entry the server gave no date, which has no place on a calendar.
  DateTime? get day {
    final date = airDate == null ? null : DateTime.tryParse(airDate!);
    return date == null ? null : DateTime(date.year, date.month, date.day);
  }

  /// Playability is having a version to play and nothing else. The server
  /// sends no separate flag, so the two cannot drift apart.
  bool get isPlayable => defaultVersionId != null;

  /// The show's name for an episode, the movie's own title for a movie.
  String get calendarTitle =>
      ref.kind == ItemKind.movie ? title : showTitle ?? '';

  /// `S02E05` for an episode, `Movie` for a movie.
  String get calendarNumbering {
    if (ref.kind == ItemKind.movie) return 'Movie';
    final season = (parentIndex ?? 0).toString().padLeft(2, '0');
    final episode = (index ?? 0).toString().padLeft(2, '0');
    return 'S${season}E$episode';
  }

  /// The numbering, then the episode title when there is one.
  String get calendarSubtitle {
    if (ref.kind == ItemKind.movie || title.isEmpty) return calendarNumbering;
    return '$calendarNumbering · $title';
  }
}

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
/// appear (the timeline adds today itself), so a sparse library gives a short
/// list rather than a grid of empty days.
List<MapEntry<DateTime, List<ItemSummary>>> groupByDay(
  List<ItemSummary> entries,
) {
  final groups = <DateTime, List<ItemSummary>>{};

  for (final entry in entries) {
    final day = entry.day;
    if (day != null) groups.putIfAbsent(day, () => []).add(entry);
  }

  return groups.entries.toList();
}

/// `October` for any day in October.
String monthName(DateTime day) => _monthNames[day.month - 1];

/// The month button's label: `October`, or `January 2027` outside [today]'s
/// year.
String formatMonth(DateTime month, DateTime today) => month.year == today.year
    ? monthName(month)
    : '${monthName(month)} ${month.year}';

/// The month sheet's title, which always names the year.
String formatMonthYear(DateTime month) => '${monthName(month)} ${month.year}';

/// The first of every month that touches `[start, end]`, oldest first.
///
/// Steps by overflowing the month field, which `DateTime` normalizes across
/// a year boundary.
List<DateTime> monthsInWindow(DateTime start, DateTime end) {
  final last = DateTime(end.year, end.month);
  final months = <DateTime>[];
  var month = DateTime(start.year, start.month);
  while (!month.isAfter(last)) {
    months.add(month);
    month = DateTime(month.year, month.month + 1);
  }
  return months;
}
