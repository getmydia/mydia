import 'package:flutter/foundation.dart';

import 'calendar_dates.dart';

/// Asks the calendar timeline to scroll to a day.
///
/// The screen owns one: the Today button and the month sheet both request
/// through it, so there is one scrolling path.
///
/// A subclass rather than a bare `ChangeNotifier` because
/// `notifyListeners` is protected, and calling it from the screen fails
/// `dart analyze --fatal-warnings`.
class CalendarJumpRequests extends ChangeNotifier {
  DateTime? _day;

  /// The last day requested, at local midnight.
  DateTime? get day => _day;

  void request(DateTime day) {
    _day = truncateToDay(day);
    notifyListeners();
  }
}
