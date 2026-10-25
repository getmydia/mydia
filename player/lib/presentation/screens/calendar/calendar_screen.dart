import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/invalidation_target.dart';
import '../../../core/cache/watcher_registry.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/browse_scaffold.dart';
import '../sources/source_browse_providers.dart';
import 'calendar_jump_requests.dart';
import 'calendar_month_sheet.dart';
import 'calendar_timeline.dart';
import 'calendar_timeline_view.dart';
import 'calendar_window.dart';

/// Whether [error] is this server saying it has no calendar. A player
/// installed from an app store can be newer than the server it talks to, and
/// the source reports the rejection as an unsupported feature.
bool isCalendarUnsupported(Object error) =>
    error is SourceException && error.kind == SourceErrorKind.unsupported;

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  /// Fed by the Today button and the month sheet. The timeline listens.
  final CalendarJumpRequests _jumps = CalendarJumpRequests();

  /// The month at the top of the timeline. Null until it first reports.
  DateTime? _month;

  @override
  void dispose() {
    _jumps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final data = ref.watch(sourceCalendarProvider(widget.sourceId));
    final window = calendarWindow(today);
    final key = SourceKeys.calendar(widget.sourceId, window.start, window.end);
    final entries = data.value ?? const <ItemSummary>[];

    return BrowseScaffold(
      icon: Icons.calendar_month_outlined,
      title: context.l10n.navCalendar,
      queryKeys: [key],
      onRefresh: () => ref.read(invalidatorProvider).invalidate([key.target]),
      actions: [
        if (entries.isNotEmpty) _monthButton(entries, today),
        TextButton(
          onPressed: () => _jumps.request(today),
          child: Text(context.l10n.calendarToday),
        ),
      ],
      body: (context, scrollTopPadding) => switch (data) {
        AsyncData(:final value) => _body(value, today, scrollTopPadding),
        AsyncError(:final error) => _error(error, scrollTopPadding),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _monthButton(List<ItemSummary> entries, DateTime today) {
    final month = _month ?? DateTime(today.year, today.month);

    return TextButton.icon(
      key: const ValueKey('calendar-month-button'),
      onPressed: () => _openMonthSheet(entries, today, month),
      icon: const Icon(Icons.expand_more_rounded),
      iconAlignment: IconAlignment.end,
      label: Text(context.l10n.monthLabel(month, today)),
    );
  }

  Future<void> _openMonthSheet(
    List<ItemSummary> entries,
    DateTime today,
    DateTime month,
  ) async {
    final window = calendarWindow(today);
    final day = await showCalendarMonthSheet(
      context,
      windowStart: window.start,
      windowEnd: window.end,
      daySummaries: daySummaries(entries),
      initialMonth: month,
      today: today,
    );
    if (!mounted) return;
    if (day != null) _jumps.request(day);
  }

  Widget _body(
    List<ItemSummary> entries,
    DateTime today,
    double scrollTopPadding,
  ) {
    if (entries.isEmpty) return _empty(scrollTopPadding);

    return CalendarTimelineView(
      entries: entries,
      today: today,
      scrollTopPadding: scrollTopPadding,
      jumpRequests: _jumps,
      onMonthChanged: (month) => setState(() => _month = month),
    );
  }

  Widget _empty(double scrollTopPadding) {
    final palette = context.palette;
    return Padding(
      key: const ValueKey('calendar-empty'),
      padding: EdgeInsets.only(top: scrollTopPadding + 80, left: 32, right: 32),
      child: Column(
        children: [
          Icon(Icons.calendar_month_outlined,
              size: 48, color: palette.textDisabled),
          const SizedBox(height: 16),
          Text(
            context.l10n.calendarEmptyTitle,
            style: TextStyle(fontSize: 17, color: palette.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.calendarEmptyBody,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.textDisabled),
          ),
        ],
      ),
    );
  }

  Widget _error(Object error, double scrollTopPadding) {
    final palette = context.palette;
    if (isCalendarUnsupported(error)) {
      return Padding(
        key: const ValueKey('calendar-unsupported'),
        padding:
            EdgeInsets.only(top: scrollTopPadding + 80, left: 32, right: 32),
        child: Column(
          children: [
            Icon(Icons.update, size: 48, color: palette.textDisabled),
            const SizedBox(height: 16),
            Text(
              context.l10n.calendarUnsupportedTitle,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: palette.textSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.calendarUnsupportedBody,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: palette.textDisabled),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: scrollTopPadding + 80, left: 32, right: 32),
      child: Column(
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: 16),
          Text(
            context.l10n.calendarLoadFailed,
            style: TextStyle(fontSize: 17, color: palette.textSecondary),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () =>
                ref.invalidate(sourceCalendarProvider(widget.sourceId)),
            child: Text(context.l10n.commonTryAgain),
          ),
        ],
      ),
    );
  }
}
