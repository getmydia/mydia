import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_keys.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/calendar_entry.dart';
import 'calendar_dates.dart';
import 'calendar_window.dart';

part 'calendar_controller.g.dart';

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

  /// See [calendarWindow]; removed with this controller.
  static (DateTime, DateTime) windowFor(DateTime today) {
    final window = calendarWindow(today);
    return (window.start, window.end);
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
