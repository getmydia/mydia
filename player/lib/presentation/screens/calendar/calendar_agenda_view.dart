import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/models/calendar_entry.dart';
import 'calendar_dates.dart';
import 'calendar_day_header.dart';
import 'calendar_row.dart';
import 'calendar_today_requests.dart';

/// Index of the first day on or after [today], or null when every day is past.
///
/// Not simply "the group whose date is today": today may have no entries at
/// all, and the calendar still has to open somewhere sensible. The first
/// upcoming day is that place.
int? indexOfToday(List<DateTime> days, DateTime today) {
  final midnight = truncateToDay(today);

  for (var i = 0; i < days.length; i++) {
    if (!days[i].isBefore(midnight)) return i;
  }
  return null;
}

/// Every day with entries in the loaded window, as one scrolling list.
///
/// Opens with today's section at the top, and returns there whenever
/// [todayRequests] fires.
class CalendarAgendaView extends StatefulWidget {
  const CalendarAgendaView({
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

  /// Room to leave above the first section for the glass bar.
  final double scrollTopPadding;

  final CalendarTodayRequests todayRequests;

  @override
  State<CalendarAgendaView> createState() => _CalendarAgendaViewState();
}

class _CalendarAgendaViewState extends State<CalendarAgendaView> {
  final ScrollController _scrollController = ScrollController();

  /// Attached to the first day section on or after today.
  ///
  /// A key rather than an offset because day sections have no fixed height:
  /// each holds a different number of rows, so there is no arithmetic that
  /// turns an index into a scroll position. `Scrollable.ensureVisible` asks
  /// the laid-out element where it actually is.
  final GlobalKey _todayKey = GlobalKey();

  /// Whether the one-time jump to today has already happened.
  ///
  /// The stream rebuilds on every refetch and cache write, and re-jumping on
  /// each of those would yank the list out from under someone who had
  /// scrolled away.
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    widget.todayRequests.addListener(_handleTodayRequest);
  }

  @override
  void didUpdateWidget(CalendarAgendaView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todayRequests != widget.todayRequests) {
      oldWidget.todayRequests.removeListener(_handleTodayRequest);
      widget.todayRequests.addListener(_handleTodayRequest);
    }
  }

  @override
  void dispose() {
    widget.todayRequests.removeListener(_handleTodayRequest);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleTodayRequest() => unawaited(_scrollToToday());

  /// Puts today's section at the top of the viewport.
  ///
  /// `alignment: 0` pins it to the leading edge rather than merely bringing it
  /// into view, so past entries sit above the fold where they belong.
  Future<void> _scrollToToday() async {
    final context = _todayKey.currentContext;
    if (context == null) return;

    await Scrollable.ensureVisible(
      context,
      alignment: 0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Jumps to today once, after the first frame that has laid the list out.
  void _jumpToTodayOnce() {
    if (_jumped) return;
    _jumped = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final context = _todayKey.currentContext;
      if (context == null) return;
      Scrollable.ensureVisible(context, alignment: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final today = widget.today;
    final groups = groupByDay(widget.entries);
    final todayIndex = indexOfToday(groups.map((g) => g.key).toList(), today);

    _jumpToTodayOnce();

    return CustomScrollView(
      key: const ValueKey('calendar-agenda-view'),
      controller: _scrollController,
      slivers: [
        // A spacer sliver, not SliverPadding: SliverPadding with no `sliver`
        // child renders nothing at all, so the glass bar would overlap the
        // first rows.
        SliverToBoxAdapter(child: SizedBox(height: widget.scrollTopPadding)),
        for (final (index, group) in groups.indexed)
          // SliverMainAxisGroup scopes the pinned header to its own group, so
          // each date header sticks only while its own rows are on screen and
          // is then pushed off by the next one. A bare pinned
          // SliverPersistentHeader would pin all of them at once and stack
          // every date at the top of the viewport.
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: CalendarDayHeaderDelegate(
                  day: group.key,
                  today: today,
                  headerKey: index == todayIndex ? _todayKey : null,
                ),
              ),
              SliverList.builder(
                itemCount: group.value.length,
                itemBuilder: (context, itemIndex) {
                  final entry = group.value[itemIndex];
                  return CalendarRow(
                    key: ValueKey('calendar-entry-${entry.id}'),
                    entry: entry,
                    today: today,
                  );
                },
              ),
            ],
          ),
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 28, 16, 40),
            child: Text(
              'That is everything scheduled in the next 90 days.',
              style: TextStyle(fontSize: 12, color: AppColors.textDisabled),
            ),
          ),
        ),
      ],
    );
  }
}
