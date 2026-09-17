import 'package:flutter/foundation.dart';

/// Pinged by the calendar screen's Today button.
///
/// The screen owns one and hands it to whichever view is showing. Each view
/// brings today into view its own way: the agenda scrolls to today's
/// section, the week view pages to today's week and selects today.
///
/// A subclass rather than a bare `ChangeNotifier` because
/// `notifyListeners` is protected, and calling it from the screen fails
/// `dart analyze --fatal-warnings`.
class CalendarTodayRequests extends ChangeNotifier {
  /// Asks the listening view to show today.
  void request() => notifyListeners();
}
