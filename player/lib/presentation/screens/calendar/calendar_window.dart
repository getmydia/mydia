/// Days of past the window reaches back.
const int kCalendarDaysBack = 30;

/// Days of future the window reaches forward.
const int kCalendarDaysForward = 90;

/// The window the calendar loads, as whole local days.
///
/// Shared by the screen and the tests so none does the arithmetic itself.
/// The server takes explicit dates because only the client knows the
/// viewer's timezone.
///
/// Built by overflowing the day field rather than adding a `Duration`:
/// `DateTime`'s constructor normalizes an out-of-range day by calendar
/// arithmetic, not by adding elapsed real time, so it lands on the right
/// calendar day even when the span crosses a daylight-saving transition. A
/// `Duration`-based add/subtract would drift by an hour across such a
/// transition, which running this in a DST-observing timezone reproduces.
({DateTime start, DateTime end}) calendarWindow(DateTime now) => (
      start: DateTime(now.year, now.month, now.day - kCalendarDaysBack),
      end: DateTime(now.year, now.month, now.day + kCalendarDaysForward),
    );
