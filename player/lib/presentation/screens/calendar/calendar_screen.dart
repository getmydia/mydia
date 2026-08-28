import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/schema_downgrade.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/calendar_entry.dart';
import '../../widgets/browse_scaffold.dart';
import 'calendar_controller.dart';
import 'calendar_dates.dart';
import 'calendar_row.dart';

/// Short weekday names, indexed by `DateTime.weekday - 1` (Monday first).
///
/// `package:intl` is not a dependency of this app (checked `pubspec.yaml`
/// before writing this), so the day header is hand-formatted from these
/// const tables rather than pulling in `DateFormat` for one label.
const List<String> _weekdayAbbreviations = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Full month names, indexed by `DateTime.month - 1`.
const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Entries grouped into day sections, in the order the server sent them.
///
/// The resolver already orders by air date, then playable first, then title,
/// so this preserves order rather than re-sorting. Days with no entries never
/// appear, which is the whole reason an agenda beats a grid on a small
/// library.
List<MapEntry<DateTime, List<CalendarEntry>>> groupByDay(
  List<CalendarEntry> entries,
) {
  final groups = <DateTime, List<CalendarEntry>>{};

  for (final entry in entries) {
    groups.putIfAbsent(entry.day, () => []).add(entry);
  }

  return groups.entries.toList();
}

/// The label above one day's entries.
String formatDayHeader(DateTime day, DateTime today) {
  final isToday = isSameDay(day, today);

  final sameYear = day.year == today.year;
  final weekday = _weekdayAbbreviations[day.weekday - 1];
  final month = _monthNames[day.month - 1];

  final formatted = sameYear
      ? '$weekday ${day.day} $month'
      : '$weekday ${day.day} $month ${day.year}';

  return isToday ? '$formatted · Today' : formatted;
}

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
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

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
    final today = DateTime.now();
    final data = ref.watch(calendarControllerProvider);

    return BrowseScaffold(
      icon: Icons.calendar_month_outlined,
      title: 'Calendar',
      queryKeys: [QueryKeys.calendar],
      onRefresh: () => ref.read(calendarControllerProvider.notifier).refresh(),
      actions: [
        TextButton(
          onPressed: _scrollToToday,
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

    final groups = groupByDay(entries);
    final todayIndex = indexOfToday(groups.map((g) => g.key).toList(), today);

    _jumpToTodayOnce();

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // A spacer sliver, not SliverPadding: SliverPadding with no `sliver`
        // child renders nothing at all, so the glass bar would overlap the
        // first rows.
        SliverToBoxAdapter(child: SizedBox(height: scrollTopPadding)),
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
                delegate: _DayHeaderDelegate(
                  headerKey: index == todayIndex ? _todayKey : null,
                  label: formatDayHeader(group.key, today),
                  isToday: isSameDay(group.key, today),
                  dayKey: ValueKey(
                    'calendar-day-${isoDate(group.key)}',
                  ),
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

class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate({
    required this.label,
    required this.isToday,
    required this.dayKey,
    this.headerKey,
  });

  final String label;
  final bool isToday;
  final Key dayKey;

  /// Carried onto the rendered header so `Scrollable.ensureVisible` has an
  /// element to target. Only the today header receives one.
  final Key? headerKey;

  static const double _height = 38;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      key: headerKey,
      height: _height,
      // Opaque, or the rows scrolling underneath a pinned header show through.
      color: AppColors.background,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Text(
        label,
        key: dayKey,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: isToday ? AppColors.primary : AppColors.textSecondary,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate oldDelegate) =>
      oldDelegate.label != label ||
      oldDelegate.isToday != isToday ||
      oldDelegate.headerKey != headerKey;
}
