import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/invalidation_target.dart';
import '../../../core/cache/watcher_registry.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/browse_scaffold.dart';
import '../sources/source_browse_providers.dart';
import 'calendar_agenda_view.dart';
import 'calendar_today_requests.dart';
import 'calendar_view_mode.dart';
import 'calendar_week_view.dart';
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
  /// Pinged by the Today button. Whichever view is showing listens.
  final CalendarTodayRequests _todayRequests = CalendarTodayRequests();

  @override
  void dispose() {
    _todayRequests.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final data = ref.watch(sourceCalendarProvider(widget.sourceId));
    final window = calendarWindow(today);
    final key = SourceKeys.calendar(widget.sourceId, window.start, window.end);
    // Null until storage answers. The body waits for it rather than mounting
    // the default view and swapping, which would flash.
    final mode = ref.watch(calendarViewModeControllerProvider).value;

    return BrowseScaffold(
      icon: Icons.calendar_month_outlined,
      title: 'Calendar',
      queryKeys: [key],
      onRefresh: () => ref.read(invalidatorProvider).invalidate([key.target]),
      actions: [
        if (mode != null) _viewToggle(mode),
        TextButton(
          onPressed: _todayRequests.request,
          child: const Text('Today'),
        ),
      ],
      body: (context, scrollTopPadding) => switch ((data, mode)) {
        (AsyncData(:final value), final CalendarViewMode loadedMode) =>
          _body(value, loadedMode, today, scrollTopPadding),
        (AsyncError(:final error), _) => _error(error, scrollTopPadding),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  /// Shows the icon of the view it switches to, like a two-state tab.
  Widget _viewToggle(CalendarViewMode mode) {
    final showingWeek = mode == CalendarViewMode.week;

    return IconButton(
      key: const ValueKey('calendar-view-toggle'),
      tooltip: showingWeek ? 'Agenda view' : 'Week view',
      icon: Icon(
        showingWeek ? Icons.view_agenda_outlined : Icons.view_week_outlined,
      ),
      onPressed: () =>
          ref.read(calendarViewModeControllerProvider.notifier).select(
                showingWeek ? CalendarViewMode.agenda : CalendarViewMode.week,
              ),
    );
  }

  Widget _body(
    List<ItemSummary> entries,
    CalendarViewMode mode,
    DateTime today,
    double scrollTopPadding,
  ) {
    if (entries.isEmpty) {
      return _empty(scrollTopPadding);
    }

    return switch (mode) {
      CalendarViewMode.week => CalendarWeekView(
          entries: entries,
          today: today,
          scrollTopPadding: scrollTopPadding,
          todayRequests: _todayRequests,
        ),
      CalendarViewMode.agenda => CalendarAgendaView(
          entries: entries,
          today: today,
          scrollTopPadding: scrollTopPadding,
          todayRequests: _todayRequests,
        ),
    };
  }

  Widget _empty(double scrollTopPadding) {
    return Padding(
      key: const ValueKey('calendar-empty'),
      padding: EdgeInsets.only(top: scrollTopPadding + 80, left: 32, right: 32),
      child: const Column(
        children: [
          Icon(Icons.calendar_month_outlined,
              size: 48, color: AppColors.textDisabled),
          SizedBox(height: 16),
          Text(
            'Nothing scheduled',
            style: TextStyle(fontSize: 17, color: AppColors.textSecondary),
          ),
          SizedBox(height: 8),
          Text(
            'The calendar covers 30 days back and 90 days ahead.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.textDisabled),
          ),
        ],
      ),
    );
  }

  Widget _error(Object error, double scrollTopPadding) {
    if (isCalendarUnsupported(error)) {
      return Padding(
        key: const ValueKey('calendar-unsupported'),
        padding:
            EdgeInsets.only(top: scrollTopPadding + 80, left: 32, right: 32),
        child: const Column(
          children: [
            Icon(Icons.update, size: 48, color: AppColors.textDisabled),
            SizedBox(height: 16),
            Text(
              'This server does not have the calendar yet',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: AppColors.textSecondary),
            ),
            SizedBox(height: 8),
            Text(
              'Update the server and the calendar will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.textDisabled),
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
          const Text(
            'The calendar could not be loaded',
            style: TextStyle(fontSize: 17, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () =>
                ref.invalidate(sourceCalendarProvider(widget.sourceId)),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
