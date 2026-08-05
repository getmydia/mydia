import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';
import 'package:player/domain/models/show_next_up.dart';
import 'package:player/domain/models/up_next_item.dart';

void main() {
  group('UpNextItem', () {
    test('parses files, progress and the typed state', () {
      final item = UpNextItem.fromJson({
        'progressState': 'continue',
        'episode': {
          'id': '9',
          'seasonNumber': 1,
          'episodeNumber': 4,
          'title': 'The You You Are',
          'hasFile': true,
          'files': [
            {'id': 'f9', 'resolution': '1080p', 'directPlaySupported': true},
          ],
          'progress': {
            'positionSeconds': 420,
            'durationSeconds': 2400,
            'percentage': 17.5,
            'watched': false,
          },
        },
        'show': {'id': 's1', 'title': 'Severance'},
      });

      expect(item.state, NextUpState.continueWatching);
      expect(item.progressState, 'continue');
      expect(item.episode.files, hasLength(1));
      expect(item.episode.progress?.positionSeconds, 420);
    });

    test('tolerates an episode with no files', () {
      final item = UpNextItem.fromJson({
        'progressState': 'start',
        'episode': {
          'id': '9',
          'seasonNumber': 1,
          'episodeNumber': 1,
          'title': 'Good News About Hell',
          'hasFile': false,
        },
        'show': {'id': 's1', 'title': 'Severance'},
      });

      expect(item.state, NextUpState.start);
      expect(item.episode.files, isEmpty);
      expect(item.episode.progress, isNull);
    });

    test('pads the episode code the way the other models do', () {
      final item = UpNextItem.fromJson({
        'progressState': 'next',
        'episode': {
          'id': '9',
          'seasonNumber': 2,
          'episodeNumber': 5,
          'title': "Woe's Hollow",
          'hasFile': true,
        },
        'show': {'id': 's1', 'title': 'Severance'},
      });

      // This string becomes the player title, so an unpadded "S2E5" here
      // would make the same episode read differently depending on whether it
      // was launched from the rail or from the show hero.
      expect(item.episode.episodeCode, 'S02E05');
      expect(item.displayTitle, 'Severance - S02E05');
    });
  });

  group('ContinueWatchingItem', () {
    test('parses files and showId', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'e1',
        'type': 'episode',
        'title': 'Half Loop',
        'showId': 's1',
        'files': [
          {'id': 'f1', 'resolution': '720p', 'directPlaySupported': false},
        ],
      });

      expect(item.showId, 's1');
      expect(item.files, hasLength(1));
      expect(item.isEpisode, isTrue);
    });

    test('zero-pads the episode code in displayTitle', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'e2',
        'type': 'episode',
        'title': 'Half Loop',
        'showTitle': 'Severance',
        'seasonNumber': 2,
        'episodeNumber': 6,
      });

      // displayTitle becomes the player title for this rail, so an unpadded
      // "S2E6" would make the same episode read differently depending on
      // whether it was launched from here or from the show detail hero.
      expect(item.displayTitle, 'Severance - S02E06');
    });

    test('falls back to the plain title for a movie', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'm1',
        'type': 'movie',
        'title': 'Arrival',
      });

      expect(item.displayTitle, 'Arrival');
    });

    test('defaults files to empty when absent', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'm1',
        'type': 'movie',
        'title': 'Arrival',
      });

      expect(item.files, isEmpty);
      expect(item.isMovie, isTrue);
    });
  });
}
