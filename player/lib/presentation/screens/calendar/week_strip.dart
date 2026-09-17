import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../widgets/focus_highlight.dart';
import 'calendar_dates.dart';

/// Seven day cells that page by week, under the week's title and its
/// previous and next arrows.
///
/// Stateless on purpose. The week view owns the selected day, the current
/// page and the [PageController], so a refetch that rebuilds this widget
/// cannot move the viewer.
///
/// Every cell is its own [FocusHighlight] stop, because on Android TV the
/// D-pad is the only way to pick a day. The arrows are ordinary
/// [IconButton]s and so are focusable too, which is how a remote pages.
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.weeks,
    required this.pageController,
    required this.currentPage,
    required this.selectedDay,
    required this.today,
    required this.windowStart,
    required this.windowEnd,
    required this.daySummaries,
    required this.onSelectDay,
    required this.onPageChanged,
  });

  /// The Monday of each page, oldest first.
  final List<DateTime> weeks;

  final PageController pageController;

  /// The page the title and arrows describe.
  ///
  /// Passed in rather than read from [pageController], whose `page` is null
  /// until the first layout.
  final int currentPage;

  final DateTime selectedDay;
  final DateTime today;

  /// The loaded window, as local midnights. Days outside it have no data, so
  /// their cells are inert.
  final DateTime windowStart;
  final DateTime windowEnd;

  /// Day to whether anything on it is playable. A day with no entries is
  /// absent.
  final Map<DateTime, bool> daySummaries;

  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<int> onPageChanged;

  /// Total height. The week view gives the strip exactly this much room.
  static const double height = 112;

  /// Fill behind the selected day.
  static final Color selectedFill = AppColors.primary.withValues(alpha: 0.16);

  static const double _titleHeight = 44;
  static const Duration _pageDuration = Duration(milliseconds: 250);

  void _goToPage(int page) {
    pageController.animateToPage(
      page,
      duration: _pageDuration,
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('calendar-week-strip'),
      height: height,
      child: Column(
        children: [
          SizedBox(
            height: _titleHeight,
            child: Row(
              children: [
                _arrow(
                  visible: currentPage > 0,
                  key: const ValueKey('calendar-week-prev'),
                  icon: Icons.chevron_left_rounded,
                  tooltip: 'Previous week',
                  onPressed: () => _goToPage(currentPage - 1),
                ),
                Expanded(
                  child: Text(
                    formatWeekLabel(weeks[currentPage]),
                    key: const ValueKey('calendar-week-label'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                _arrow(
                  visible: currentPage < weeks.length - 1,
                  key: const ValueKey('calendar-week-next'),
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'Next week',
                  onPressed: () => _goToPage(currentPage + 1),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: pageController,
              itemCount: weeks.length,
              onPageChanged: onPageChanged,
              itemBuilder: (context, page) => _buildWeek(weeks[page]),
            ),
          ),
        ],
      ),
    );
  }

  /// A hidden arrow keeps its 48px so the title stays centred, but leaves the
  /// tree entirely: a focusable button that does nothing is a dead stop for a
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
      key: key,
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  Widget _buildWeek(DateTime weekStart) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (var offset = 0; offset < DateTime.daysPerWeek; offset++)
            Expanded(
              child: _buildDay(
                DateTime(
                    weekStart.year, weekStart.month, weekStart.day + offset),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDay(DateTime day) {
    final inWindow = !day.isBefore(windowStart) && !day.isAfter(windowEnd);

    return _DayCell(
      day: day,
      selected: isSameDay(day, selectedDay),
      isToday: isSameDay(day, today),
      inWindow: inWindow,
      hasPlayable: daySummaries[day],
      onSelect: inWindow ? () => onSelectDay(day) : null,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.isToday,
    required this.inWindow,
    required this.hasPlayable,
    required this.onSelect,
  });

  final DateTime day;
  final bool selected;
  final bool isToday;
  final bool inWindow;

  /// Null when the day has no entries.
  final bool? hasPlayable;

  /// Null for a day outside the window, which makes the cell unfocusable.
  final VoidCallback? onSelect;

  static const BorderRadius _radius = BorderRadius.all(Radius.circular(10));

  @override
  Widget build(BuildContext context) {
    final Color numberColor;
    if (!inWindow) {
      numberColor = AppColors.textDisabled;
    } else if (isToday) {
      numberColor = AppColors.primary;
    } else {
      numberColor = AppColors.textPrimary;
    }

    return FocusHighlight(
      onActivate: onSelect,
      borderRadius: _radius,
      child: InkWell(
        onTap: onSelect,
        // FocusHighlight above is the single focus stop for this cell.
        // InkWell defaults canRequestFocus to true, which would otherwise
        // register a second, invisible focus stop nested inside the first.
        canRequestFocus: false,
        borderRadius: _radius,
        child: Container(
          key: ValueKey('calendar-week-day-${isoDate(day)}'),
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? WeekStrip.selectedFill : null,
            borderRadius: _radius,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                weekdayAbbreviation(day),
                style: TextStyle(
                  fontSize: 12,
                  color: inWindow
                      ? AppColors.textSecondary
                      : AppColors.textDisabled,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${day.day}',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: numberColor,
                ),
              ),
              const SizedBox(height: 6),
              _dot(),
            ],
          ),
        ),
      ),
    );
  }

  /// Always 6px tall, dot or not, so every cell lines up.
  Widget _dot() {
    final playable = hasPlayable;
    if (playable == null) return const SizedBox(width: 6, height: 6);

    return Container(
      key: ValueKey('calendar-week-dot-${isoDate(day)}'),
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: playable ? AppColors.primary : AppColors.textDisabled,
      ),
    );
  }
}
