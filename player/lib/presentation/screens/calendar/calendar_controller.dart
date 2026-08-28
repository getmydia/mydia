import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/calendar_entry.dart';
import 'calendar_dates.dart';

part 'calendar_controller.g.dart';

/// Days of past the window reaches back.
const int kCalendarDaysBack = 30;

/// Days of future the window reaches forward.
const int kCalendarDaysForward = 90;

const String calendarQuery = r'''
query Calendar($start: Date!, $end: Date!) {
  calendar(start: $start, end: $end) {
    id
    kind
    airDate
    title
    seasonNumber
    episodeNumber
    mediaItemId
    mediaItemTitle
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    files {
      id
      resolution
      directPlaySupported
      hdrFormat
      bitrate
    }
  }
}
''';

/// Turns a `calendar` response into entries.
///
/// Top-level rather than a closure inside `build` so the watcher test can
/// exercise the real parse instead of a copy of it that could drift.
List<CalendarEntry> parseCalendar(Map<String, dynamic> data) {
  return (data['calendar'] as List<dynamic>?)
          ?.map((e) => CalendarEntry.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [];
}

@riverpod
class CalendarController extends _$CalendarController {
  late QueryWatcher<List<CalendarEntry>> _watcher;

  /// The window the calendar loads, as whole local days.
  ///
  /// Exposed so the screen and the tests share one definition instead of
  /// each doing the arithmetic. The server takes explicit dates because only
  /// the client knows the viewer's timezone.
  ///
  /// Built by overflowing the day field rather than adding a `Duration`:
  /// `DateTime`'s constructor normalizes an out-of-range day by calendar
  /// arithmetic, not by adding elapsed real time, so it lands on the right
  /// calendar day even when the span crosses a daylight-saving transition. A
  /// `Duration`-based add/subtract would drift by an hour across such a
  /// transition, which running this in a DST-observing timezone reproduces.
  static (DateTime, DateTime) windowFor(DateTime today) {
    return (
      DateTime(today.year, today.month, today.day - kCalendarDaysBack),
      DateTime(today.year, today.month, today.day + kCalendarDaysForward),
    );
  }

  @override
  Stream<List<CalendarEntry>> build() {
    final (start, end) = windowFor(DateTime.now());

    _watcher = createWatcher<List<CalendarEntry>>(
      ref,
      key: QueryKeys.calendar,
      document: gql(calendarQuery),
      variables: {'start': isoDate(start), 'end': isoDate(end)},
      parse: parseCalendar,
    );

    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
