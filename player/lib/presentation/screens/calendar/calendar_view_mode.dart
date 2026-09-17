import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../settings/settings_controller.dart';

part 'calendar_view_mode.g.dart';

/// Which layout the calendar screen shows.
enum CalendarViewMode {
  /// A week strip with one day's entries below it. The default.
  week,

  /// Every day with entries in the loaded window, as one list.
  agenda;

  /// The value written to settings storage.
  String encode() => name;

  /// Reads a stored value back.
  ///
  /// Anything unrecognised, including nothing stored yet, is [week]. A value
  /// from a later build that this one does not know must not strand the
  /// calendar.
  static CalendarViewMode decode(String? raw) =>
      values.firstWhere((mode) => mode.name == raw, orElse: () => week);
}

/// The calendar layout this device last chose.
///
/// The screen waits for this before choosing a view, rather than mounting
/// the default and swapping once storage answers, which would flash.
@riverpod
class CalendarViewModeController extends _$CalendarViewModeController {
  @override
  Future<CalendarViewMode> build() async {
    final settings = ref.read(settingsServiceProvider);

    try {
      return CalendarViewMode.decode(await settings.getCalendarViewMode());
    } catch (_) {
      // A keychain that refuses the read must not keep the calendar on a
      // spinner. The default is a perfectly good calendar.
      return CalendarViewMode.week;
    }
  }

  /// Switches to [mode] and remembers it on this device.
  ///
  /// The screen changes first. A write that fails leaves the choice in place
  /// for this session; it only means the next launch opens on the old one.
  Future<void> select(CalendarViewMode mode) async {
    final settings = ref.read(settingsServiceProvider);
    state = AsyncData(mode);

    try {
      await settings.setCalendarViewMode(mode.encode());
    } catch (_) {
      // See the doc comment: nothing to surface.
    }
  }
}
