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

  /// `S02E05` for an episode, null for a movie, which the widget labels with
  /// its own translated word.
  String? get episodeCode {
    if (ref.kind == ItemKind.movie) return null;
    final season = (parentIndex ?? 0).toString().padLeft(2, '0');
    final episode = (index ?? 0).toString().padLeft(2, '0');
    return 'S${season}E$episode';
  }
}

/// [date] with its time-of-day dropped, at local midnight.
DateTime truncateToDay(DateTime date) =>
    DateTime(date.year, date.month, date.day);

/// Whether [a] and [b] fall on the same calendar day, ignoring time-of-day.
bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

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
