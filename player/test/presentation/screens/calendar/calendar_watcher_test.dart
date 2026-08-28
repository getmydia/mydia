import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/query_watcher.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_controller.dart';

import '../../../test_utils/stub_graphql_client.dart';

// `gql()` injects a `__typename` selection into every selection set, the
// operation root included, and cache normalization rejects data that lacks a
// matching one. That failure surfaces as a spurious `hasException`, not as an
// obvious error, so every object below carries one.
Map<String, dynamic> _calendarData() => {
      '__typename': 'Query',
      'calendar': [
        {
          '__typename': 'CalendarEntry',
          'id': '42',
          'kind': 'EPISODE',
          'airDate': '2026-08-27',
          'title': 'An Episode',
          'seasonNumber': 3,
          'episodeNumber': 4,
          'mediaItemId': '7',
          'mediaItemTitle': 'A Show',
          'artwork': {
            '__typename': 'Artwork',
            'posterUrl': 'https://example.invalid/p.jpg',
            'backdropUrl': null,
            'thumbnailUrl': null,
          },
          'files': [
            {
              '__typename': 'MediaFile',
              'id': 'file-1',
              'resolution': '1080p',
              'directPlaySupported': true,
              'hdrFormat': null,
              'bitrate': 8000000,
            },
          ],
        },
        {
          '__typename': 'CalendarEntry',
          'id': '43',
          'kind': 'MOVIE',
          'airDate': '2026-08-28',
          'title': 'A Movie',
          'seasonNumber': null,
          'episodeNumber': null,
          'mediaItemId': '43',
          'mediaItemTitle': 'A Movie',
          'artwork': null,
          'files': <dynamic>[],
        },
      ],
    };

void main() {
  QueryWatcher<List<CalendarEntry>> watcherFor(GraphQLClient client) {
    return QueryWatcher<List<CalendarEntry>>(
      key: QueryKeys.calendar,
      client: Future<GraphQLClient>.value(client),
      fetchLog: InMemoryFetchLog(),
      document: gql(calendarQuery),
      variables: const {'start': '2026-07-28', 'end': '2026-11-25'},
      parse: parseCalendar,
    );
  }

  test('parses a real calendar response into entries', () async {
    final watcher =
        watcherFor(stubClient(StubLink.responses([_calendarData()])));
    addTearDown(watcher.close);

    final entries = await watcher.stream.first;

    // Assert the parsed values, never merely that nothing threw: StubLink
    // can fail silently, and an empty list would satisfy a weaker assertion.
    expect(entries, hasLength(2));
    expect(entries.first.id, '42');
    expect(entries.first.kind, CalendarEntryKind.episode);
    expect(entries.first.mediaItemTitle, 'A Show');
    expect(entries.first.files.single.id, 'file-1');
    expect(entries.first.isPlayable, isTrue);
    expect(entries.last.kind, CalendarEntryKind.movie);
    expect(entries.last.isPlayable, isFalse);
  });

  test('an empty window parses to an empty list, not an error', () async {
    final watcher = watcherFor(
      stubClient(
        StubLink.responses([
          {'__typename': 'Query', 'calendar': <dynamic>[]},
        ]),
      ),
    );
    addTearDown(watcher.close);

    await expectLater(watcher.stream, emits(isEmpty));
  });

  test('sends the window as variables', () async {
    final link = StubLink.responses([_calendarData()]);
    final watcher = watcherFor(stubClient(link));
    addTearDown(watcher.close);

    await watcher.stream.first;

    expect(link.requests.first.variables['start'], '2026-07-28');
    expect(link.requests.first.variables['end'], '2026-11-25');
  });
}
