import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/schema_downgrade.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/calendar_entry.dart';
import '../../widgets/browse_scaffold.dart';
import 'calendar_agenda_view.dart';
import 'calendar_controller.dart';
import 'calendar_today_requests.dart';

/// Whether [error] is this server saying it has no calendar query.
///
/// A player installed from an app store can be newer than the server it talks
/// to. There is no capability probe to ask in advance: `serverCompatibility`
/// reports version strings and no feature list, and a brand new root field has
/// no older shape for `QueryWatcher` to fall back to. So the rejection itself
/// is the signal.
bool isCalendarUnsupported(Object error) {
  if (error is! OperationException) return false;
  return isUnknownFieldError(error);
}

class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

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
    final data = ref.watch(calendarControllerProvider);

    return BrowseScaffold(
      icon: Icons.calendar_month_outlined,
      title: 'Calendar',
      queryKeys: [QueryKeys.calendar],
      onRefresh: () => ref.read(calendarControllerProvider.notifier).refresh(),
      actions: [
        TextButton(
          onPressed: _todayRequests.request,
          child: const Text('Today'),
        ),
      ],
      body: (context, scrollTopPadding) => switch (data) {
        AsyncData(:final value) => _body(value, today, scrollTopPadding),
        AsyncError(:final error) => _error(error, scrollTopPadding),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }

  Widget _body(
    List<CalendarEntry> entries,
    DateTime today,
    double scrollTopPadding,
  ) {
    if (entries.isEmpty) {
      return _empty(scrollTopPadding);
    }

    return CalendarAgendaView(
      entries: entries,
      today: today,
      scrollTopPadding: scrollTopPadding,
      todayRequests: _todayRequests,
    );
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
                ref.read(calendarControllerProvider.notifier).refresh(),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
