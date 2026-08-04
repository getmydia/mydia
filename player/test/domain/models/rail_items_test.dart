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
