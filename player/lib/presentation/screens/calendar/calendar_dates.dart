/// Shared date helpers for the calendar screen.
///
/// The calendar throws away time-of-day at several independent points: to
/// send the window's `start`/`end` to the server, to decide which day
/// section is "today", and to group and compare entries by calendar day.
/// Kept in one file so those points cannot drift into subtly different
/// definitions of "day" from one another.
library;

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
