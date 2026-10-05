import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/plex/plex_mapping.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/domain/sources/library.dart';

void main() {
  const sid = SourceId('acc1:owner:abc123');

  test('a summary carries sort title, added and last played', () {
    final s = plexSummary(sid, {
      'ratingKey': '101',
      'type': 'movie',
      'title': 'The Lantern Keeper',
      'titleSort': 'Lantern Keeper',
      'addedAt': 1700000000,
      'lastViewedAt': 1700086400,
    })!;
    expect(s.sortTitle, 'Lantern Keeper');
    expect(s.addedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
    expect(s.lastPlayedAt,
        DateTime.fromMillisecondsSinceEpoch(1700086400000, isUtc: true));
  });

  test('missing keys stay null', () {
    final s =
        plexSummary(sid, {'ratingKey': '1', 'type': 'movie', 'title': 'X'})!;
    expect(s.sortTitle, isNull);
    expect(s.addedAt, isNull);
    expect(s.lastPlayedAt, isNull);
  });

  test('sort options tag title, added and released', () {
    final shared = {for (final o in plexSortOptions) o.id: o.shared};
    expect(shared, {
      'titleSort': SharedSort.title,
      'addedAt': SharedSort.added,
      'originallyAvailableAt': SharedSort.released,
      'audienceRating': null,
      'lastViewedAt': null,
    });
  });

  group('plexSegments', () {
    test('keeps intro and credits, drops the rest', () {
      final segments = plexSegments({
        'Marker': [
          {'type': 'intro', 'startTimeOffset': 1000, 'endTimeOffset': 61000},
          {
            'type': 'commercial',
            'startTimeOffset': 70000,
            'endTimeOffset': 90000
          },
          {
            'type': 'credits',
            'startTimeOffset': 1700000,
            'endTimeOffset': 1800000,
            'final': true
          },
          {'type': 'intro', 'startTimeOffset': 5000, 'endTimeOffset': 5000},
          {'type': 'credits'},
          'not a map',
        ],
      });
      expect(segments, const [
        MediaSegment(type: SegmentType.intro, startMs: 1000, endMs: 61000),
        MediaSegment(
            type: SegmentType.credits, startMs: 1700000, endMs: 1800000),
      ]);
    });

    test('no Marker field is no segments', () {
      expect(plexSegments({}), isEmpty);
    });
  });
}
