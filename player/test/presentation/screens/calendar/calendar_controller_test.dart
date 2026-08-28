import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/calendar_entry.dart';
import 'package:player/presentation/screens/calendar/calendar_controller.dart';

void main() {
  group('CalendarEntry.fromJson', () {
    test('parses an episode with a playable file', () {
      final entry = CalendarEntry.fromJson({
        'id': '42',
        'kind': 'EPISODE',
        'airDate': '2026-08-27',
        'title': 'An Episode',
        'seasonNumber': 3,
        'episodeNumber': 4,
        'mediaItemId': '7',
        'mediaItemTitle': 'A Show',
        'artwork': {'posterUrl': 'https://example.invalid/p.jpg'},
        'files': [
          {'id': 'file-1', 'resolution': '1080p', 'directPlaySupported': true},
        ],
      });

      expect(entry.id, '42');
      expect(entry.kind, CalendarEntryKind.episode);
      expect(entry.airDate, DateTime(2026, 8, 27));
      expect(entry.seasonNumber, 3);
      expect(entry.mediaItemId, '7');
      expect(entry.mediaItemTitle, 'A Show');
      expect(entry.files.single.id, 'file-1');
      expect(entry.isPlayable, isTrue);
    });

    test('parses a movie with no files as not playable', () {
      final entry = CalendarEntry.fromJson({
        'id': '9',
        'kind': 'MOVIE',
        'airDate': '2026-08-28',
        'title': 'A Movie',
        'seasonNumber': null,
        'episodeNumber': null,
        'mediaItemId': '9',
        'mediaItemTitle': 'A Movie',
        'artwork': null,
        'files': <dynamic>[],
      });

      expect(entry.kind, CalendarEntryKind.movie);
      expect(entry.seasonNumber, isNull);
      expect(entry.isPlayable, isFalse);
    });
  });

  group('CalendarController.windowFor', () {
    test('spans 30 days back and 90 forward from the given day', () {
      final (start, end) = CalendarController.windowFor(DateTime(2026, 8, 27));

      expect(start, DateTime(2026, 7, 28));
      expect(end, DateTime(2026, 11, 25));
    });

    test('drops the time component so the window is whole days', () {
      final (start, end) =
          CalendarController.windowFor(DateTime(2026, 8, 27, 23, 59, 59));

      expect(start, DateTime(2026, 7, 28));
      expect(end, DateTime(2026, 11, 25));
    });
  });
}
