import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/models/calendar_entry.dart';
import 'calendar_controller.dart';
import 'calendar_dates.dart';
import 'calendar_day_header.dart';
import 'calendar_row.dart';
import 'calendar_today_requests.dart';
import 'week_strip.dart';

/// The day in the week starting [weekStart] that shares [day]'s weekday,
/// pulled into `[windowStart, windowEnd]`.
///
/// Paging keeps the weekday, so Wed 16 becomes Wed 23, as calendar apps do.
/// Only the first and last weeks of the window are partial, so only they
/// ever clamp.
DateTime sameWeekdayIn(
  DateTime weekStart,
  DateTime day, {
  required DateTime windowStart,
  required DateTime windowEnd,
}) {
  final candidate = DateTime(
    weekStart.year,
    weekStart.month,
    weekStart.day + day.weekday - DateTime.monday,
  );

  if (candidate.isBefore(windowStart)) return windowStart;
  if (candidate.isAfter(windowEnd)) return windowEnd;
  return candidate;
}

/// One week at a time: a [WeekStrip] above the selected day's entries.
///
/// Pages only within the window [CalendarController] loaded, so every day
/// the strip can show already has its data and paging never fetches.
class CalendarWeekView extends StatefulWidget {
  const CalendarWeekView({
    super.key,
    required this.entries,
    required this.today,
    required this.scrollTopPadding,
    required this.todayRequests,
  });

  /// Never empty: the screen shows its own empty state instead.
  final List<CalendarEntry> entries;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  /// Room to leave above the strip for the glass bar.
  final double scrollTopPadding;

  final CalendarTodayRequests todayRequests;

  @override
  State<CalendarWeekView> createState() => _CalendarWeekViewState();
}

class _CalendarWeekViewState extends State<CalendarWeekView> {
  static const Duration _pageDuration = Duration(milliseconds: 250);

  // Fixed when the view mounts, matching the window the controller loaded. A
  // refetch rebuilds this widget and must not move the viewer.
  late final DateTime _windowStart;
  late final DateTime _windowEnd;
  late final List<DateTime> _weeks;
  late final PageController _pageController;

  late DateTime _selectedDay;
  late int _page;

  @override
  void initState() {
    super.initState();
    final (start, end) = CalendarController.windowFor(widget.today);
    _windowStart = start;
    _windowEnd = end;
    _weeks = weeksInWindow(start, end);
    _selectedDay = truncateToDay(widget.today);
    _page = _pageOf(_selectedDay);
    _pageController = PageController(initialPage: _page);
    widget.todayRequests.addListener(_handleTodayRequest);
  }

  @override
  void didUpdateWidget(CalendarWeekView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todayRequests != widget.todayRequests) {
      oldWidget.todayRequests.removeListener(_handleTodayRequest);
      widget.todayRequests.addListener(_handleTodayRequest);
    }
  }

  @override
  void dispose() {
    widget.todayRequests.removeListener(_handleTodayRequest);
    _pageController.dispose();
    super.dispose();
  }

  int _pageOf(DateTime day) {
    final index = _weeks.indexOf(startOfWeek(day));
    return index < 0 ? 0 : index;
  }

  void _handlePageChanged(int page) {
    setState(() {
      _page = page;
      _selectedDay = sameWeekdayIn(
        _weeks[page],
        _selectedDay,
        windowStart: _windowStart,
        windowEnd: _windowEnd,
      );
    });
  }

  void _handleSelectDay(DateTime day) {
    setState(() => _selectedDay = day);
  }

  void _handleTodayRequest() {
    final today = truncateToDay(widget.today);
    final page = _pageOf(today);

    // Selecting first means every page change the animation passes through
    // maps to today's weekday, and the last one lands on today itself.
    setState(() => _selectedDay = today);

    if (page != _page && _pageController.hasClients) {
      _pageController.animateToPage(
        page,
        duration: _pageDuration,
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = Map.fromEntries(groupByDay(widget.entries));
    final daySummaries = {
      for (final MapEntry(:key, :value) in days.entries)
        key: value.any((entry) => entry.isPlayable),
    };
    final dayEntries = days[_selectedDay] ?? const <CalendarEntry>[];

    return Column(
      key: const ValueKey('calendar-week-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: widget.scrollTopPadding),
        WeekStrip(
          weeks: _weeks,
          pageController: _pageController,
          currentPage: _page,
          selectedDay: _selectedDay,
          today: widget.today,
          windowStart: _windowStart,
          windowEnd: _windowEnd,
          daySummaries: daySummaries,
          onSelectDay: _handleSelectDay,
          onPageChanged: _handlePageChanged,
        ),
        // Outside the scroll view rather than a pinned sliver: BrowseScaffold
        // draws its glass bar over the body, and a pinned sliver sticks at the
        // viewport top, behind that bar.
        Expanded(
          child: CustomScrollView(
            // Always scrollable, so pull-to-refresh still works on a day with
            // one row or none.
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: CalendarDayHeader(
                  day: _selectedDay,
                  today: widget.today,
                ),
              ),
              if (dayEntries.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    key: ValueKey('calendar-week-empty-day'),
                    padding: EdgeInsets.fromLTRB(16, 24, 16, 24),
                    child: Text(
                      'Nothing scheduled this day',
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.textDisabled,
                      ),
                    ),
                  ),
                )
              else
                SliverList.builder(
                  itemCount: dayEntries.length,
                  itemBuilder: (context, index) {
                    final entry = dayEntries[index];
                    return CalendarRow(
                      key: ValueKey('calendar-entry-${entry.id}'),
                      entry: entry,
                      today: widget.today,
                    );
                  },
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          ),
        ),
      ],
    );
  }
}
