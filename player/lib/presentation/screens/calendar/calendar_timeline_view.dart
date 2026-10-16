import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import 'calendar_day_group.dart';
import 'calendar_jump_requests.dart';
import 'calendar_timeline.dart';

/// Every day with entries in the loaded window as one list, opening on
/// today.
///
/// Every row has a fixed extent from [TimelineLayout], so the offset of any
/// day is known before it is built: opening on today, the Today button and a
/// day picked in the month sheet are all one `animateTo`.
class CalendarTimelineView extends StatefulWidget {
  const CalendarTimelineView({
    super.key,
    required this.entries,
    required this.today,
    required this.scrollTopPadding,
    required this.jumpRequests,
    required this.onMonthChanged,
  });

  /// Never empty: the screen shows its own empty state instead.
  final List<ItemSummary> entries;

  /// Injected rather than read from the clock so tests are deterministic.
  final DateTime today;

  /// Room to leave above the first row for the glass bar.
  final double scrollTopPadding;

  final CalendarJumpRequests jumpRequests;

  /// The month of the day at the top, each time it changes.
  final ValueChanged<DateTime> onMonthChanged;

  @override
  State<CalendarTimelineView> createState() => _CalendarTimelineViewState();
}

class _CalendarTimelineViewState extends State<CalendarTimelineView> {
  static const Duration _jumpDuration = Duration(milliseconds: 250);

  /// The closing line, fixed so [_maxOffset] is exact.
  static const double _footerHeight = 44;

  ScrollController? _controller;
  TimelineGeometry? _geometry;
  DateTime? _month;

  /// The furthest the list scrolls, computed rather than read from the
  /// position: the lazy list only estimates its length until it has laid out
  /// the end, so `maxScrollExtent` can be far short when a jump is requested.
  double _maxOffset = 0;

  @override
  void initState() {
    super.initState();
    widget.jumpRequests.addListener(_handleJump);
  }

  @override
  void didUpdateWidget(CalendarTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jumpRequests != widget.jumpRequests) {
      oldWidget.jumpRequests.removeListener(_handleJump);
      widget.jumpRequests.addListener(_handleJump);
    }
  }

  @override
  void dispose() {
    widget.jumpRequests.removeListener(_handleJump);
    _controller?.dispose();
    super.dispose();
  }

  /// Created on the first layout, because where today sits depends on the
  /// width. Kept afterwards: a refetch rebuilds this widget and must not move
  /// the viewer.
  ScrollController _controllerFor(TimelineGeometry geometry) {
    final existing = _controller;
    if (existing != null) return existing;

    final controller = ScrollController(
      initialScrollOffset: geometry.offsetOf(widget.today),
    )..addListener(_reportMonth);
    _controller = controller;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.hasClients) return;
      // A today near the end of the window cannot reach the top; settle at
      // the end rather than hang past it.
      if (controller.offset > _maxOffset) controller.jumpTo(_maxOffset);
      _reportMonth();
    });
    return controller;
  }

  void _handleJump() {
    final day = widget.jumpRequests.day;
    final geometry = _geometry;
    final controller = _controller;
    if (day == null || geometry == null || controller == null) return;
    if (!controller.hasClients) return;

    controller.animateTo(
      math.min(geometry.offsetOf(day), _maxOffset),
      duration: _jumpDuration,
      curve: Curves.easeOut,
    );
  }

  void _reportMonth() {
    final controller = _controller;
    final geometry = _geometry;
    if (controller == null || geometry == null || !controller.hasClients) {
      return;
    }
    final day = geometry.dayAt(controller.offset);
    if (day == null) return;

    final month = DateTime(day.year, day.month);
    if (month == _month) return;
    _month = month;
    widget.onMonthChanged(month);
  }

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = TimelineLayout(
          width: constraints.maxWidth,
          textScale: textScale,
        );
        final items = buildTimeline(widget.entries, widget.today);
        final geometry = TimelineGeometry(items, layout);
        _geometry = geometry;
        _maxOffset = math.max(
          0,
          widget.scrollTopPadding +
              geometry.totalExtent +
              _footerHeight +
              DockInsets.bottomOf(context) -
              constraints.maxHeight,
        );

        return CustomScrollView(
          key: const ValueKey('calendar-timeline'),
          controller: _controllerFor(geometry),
          // Always scrollable, so pull-to-refresh works on a short window.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // A spacer sliver, not SliverPadding: SliverPadding with no
            // `sliver` child renders nothing at all, so the glass bar would
            // overlap the first rows.
            SliverToBoxAdapter(
              child: SizedBox(height: widget.scrollTopPadding),
            ),
            SliverVariedExtentList.builder(
              itemCount: items.length,
              itemExtentBuilder: (index, _) =>
                  index < items.length ? geometry.extentAt(index) : null,
              itemBuilder: (context, index) => Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: layout.contentWidth,
                  child: switch (items[index]) {
                    final MonthDivider divider =>
                      CalendarMonthRule(month: divider.month),
                    final TimelineDay day => CalendarDayGroup(
                        item: day,
                        today: widget.today,
                        layout: layout,
                      ),
                  },
                ),
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(
                height: _footerHeight,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 28, 16, 0),
                  child: Center(
                    child: Text(
                      'That is everything scheduled in the next 90 days.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 16 / 12,
                        color: AppColors.textDisabled,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SliverDockGap(),
          ],
        );
      },
    );
  }
}
