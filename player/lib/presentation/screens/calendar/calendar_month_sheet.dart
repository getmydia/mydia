import 'package:flutter/material.dart';

import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/focus_highlight.dart';
import '../../widgets/glass/glass_sheet.dart';
import 'calendar_dates.dart';

/// Opens the month sheet and returns the day picked, or null when dismissed.
Future<DateTime?> showCalendarMonthSheet(
  BuildContext context, {
  required DateTime windowStart,
  required DateTime windowEnd,
  required Map<DateTime, bool> daySummaries,
  required DateTime initialMonth,
  required DateTime today,
}) =>
    showGlassSheet<DateTime>(
      context: context,
      backgroundColor: context.palette.surface,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => CalendarMonthSheet(
        windowStart: windowStart,
        windowEnd: windowEnd,
        daySummaries: daySummaries,
        initialMonth: initialMonth,
        today: today,
      ),
    );

/// A month grid for jumping the calendar to a day.
///
/// Pages only across months the loaded window touches, and days outside the
/// window are inert, so every day it offers already has its data.
class CalendarMonthSheet extends StatefulWidget {
  const CalendarMonthSheet({
    super.key,
    required this.windowStart,
    required this.windowEnd,
    required this.daySummaries,
    required this.initialMonth,
    required this.today,
  });

  final DateTime windowStart;
  final DateTime windowEnd;

  /// Day to whether anything on it is playable. A day with no entries is
  /// absent.
  final Map<DateTime, bool> daySummaries;

  final DateTime initialMonth;
  final DateTime today;

  @override
  State<CalendarMonthSheet> createState() => _CalendarMonthSheetState();
}

class _CalendarMonthSheetState extends State<CalendarMonthSheet> {
  late final List<DateTime> _months =
      monthsInWindow(widget.windowStart, widget.windowEnd);
  late int _index = _initialIndex();

  int _initialIndex() {
    final month = DateTime(widget.initialMonth.year, widget.initialMonth.month);
    final index = _months.indexOf(month);
    return index < 0 ? 0 : index;
  }

  /// Any fixed Monday-first week gives the grid's header its letters.
  static final DateTime _aMonday = DateTime(2026, 1, 5);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final month = _months[_index];

    // Scrolls so a six-week month still fits the capped sheet height on a
    // landscape phone or a TV.
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.monthYear(month),
                      key: const ValueKey('calendar-sheet-title'),
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: palette.textPrimary,
                      ),
                    ),
                  ),
                  _arrow(
                    visible: _index > 0,
                    key: const ValueKey('calendar-sheet-prev'),
                    icon: Icons.chevron_left_rounded,
                    tooltip: context.l10n.calendarPreviousMonth,
                    onPressed: () => setState(() => _index--),
                  ),
                  _arrow(
                    visible: _index < _months.length - 1,
                    key: const ValueKey('calendar-sheet-next'),
                    icon: Icons.chevron_right_rounded,
                    tooltip: context.l10n.calendarNextMonth,
                    onPressed: () => setState(() => _index++),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < DateTime.daysPerWeek; i++)
                    Expanded(
                      child: Text(
                        context.l10n.weekdayNarrow(
                          DateTime(
                              _aMonday.year, _aMonday.month, _aMonday.day + i),
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: palette.textDisabled,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              for (final week in _weeks(month))
                Row(
                  children: [
                    for (final day in week)
                      Expanded(
                        child: day == null
                            ? const SizedBox(height: 40)
                            : _cell(day),
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _LegendDot(
                      color: palette.primary,
                      label: context.l10n.calendarLegendPlayable),
                  const SizedBox(width: 16),
                  _LegendDot(
                      color: palette.textDisabled,
                      label: context.l10n.calendarLegendScheduled),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A hidden arrow keeps its 48px so the title does not shift, but leaves
  /// the tree: a focusable button that does nothing is a dead stop for a
  /// remote.
  Widget _arrow({
    required bool visible,
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    if (!visible) return const SizedBox(width: 48, height: 48);
    return IconButton(
        key: key, icon: Icon(icon), tooltip: tooltip, onPressed: onPressed);
  }

  /// The month's days in Monday-first weeks, padded with nulls.
  List<List<DateTime?>> _weeks(DateTime month) {
    final leading = DateTime(month.year, month.month).weekday - DateTime.monday;
    final length = DateTime(month.year, month.month + 1, 0).day;
    final cells = <DateTime?>[
      for (var i = 0; i < leading; i++) null,
      for (var d = 1; d <= length; d++) DateTime(month.year, month.month, d),
    ];
    while (cells.length % DateTime.daysPerWeek != 0) {
      cells.add(null);
    }
    return [
      for (var i = 0; i < cells.length; i += DateTime.daysPerWeek)
        cells.sublist(i, i + DateTime.daysPerWeek),
    ];
  }

  Widget _cell(DateTime day) {
    final inWindow =
        !day.isBefore(widget.windowStart) && !day.isAfter(widget.windowEnd);
    final isToday = isSameDay(day, widget.today);
    final onSelect = inWindow ? () => Navigator.of(context).pop(day) : null;
    const radius = BorderRadius.all(Radius.circular(10));
    final palette = context.palette;

    final Color numberColor;
    if (!inWindow) {
      numberColor = palette.textDisabled;
    } else if (isToday) {
      numberColor = palette.primary;
    } else {
      numberColor = palette.textPrimary;
    }

    return FocusHighlight(
      onActivate: onSelect,
      borderRadius: radius,
      child: InkWell(
        key: ValueKey('calendar-sheet-day-${isoDate(day)}'),
        onTap: onSelect,
        // FocusHighlight above is the single focus stop for this cell.
        canRequestFocus: false,
        borderRadius: radius,
        child: SizedBox(
          height: 40,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: inWindow ? FontWeight.w600 : FontWeight.w400,
                  color: numberColor,
                ),
              ),
              const SizedBox(height: 3),
              _dot(day),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(DateTime day) {
    final playable = widget.daySummaries[day];
    if (playable == null) return const SizedBox(width: 5, height: 5);
    final state = playable ? 'playable' : 'scheduled';
    final palette = context.palette;

    return Container(
      key: ValueKey('calendar-sheet-dot-$state-${isoDate(day)}'),
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: playable ? palette.primary : palette.textDisabled,
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(label,
            style:
                TextStyle(fontSize: 11, color: context.palette.textDisabled)),
      ],
    );
  }
}
