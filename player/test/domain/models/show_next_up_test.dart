import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/show_detail.dart';
import 'package:player/domain/models/show_next_up.dart';

void main() {
  group('nextUpStateFromString', () {
    test('maps the three server states', () {
      expect(nextUpStateFromString('continue'), NextUpState.continueWatching);
      expect(nextUpStateFromString('next'), NextUpState.next);
      expect(nextUpStateFromString('start'), NextUpState.start);
    });

    test('maps anything unrecognized to unknown', () {
      expect(nextUpStateFromString('rewatch'), NextUpState.unknown);
      expect(nextUpStateFromString(''), NextUpState.unknown);
      expect(nextUpStateFromString(null), NextUpState.unknown);
    });
  });

  group('ShowNextUp.fromJson', () {
    test('parses state, episode, files and progress', () {
      final nextUp = ShowNextUp.fromJson({
        'progressState': 'continue',
        'episode': {
          'id': '42',
          'seasonNumber': 2,
          'episodeNumber': 5,
          'title': 'Woe\'s Hollow',
          'runtime': 45,
          'files': [
            {'id': 'f1', 'resolution': '1080p', 'directPlaySupported': true},
          ],
          'progress': {
            'positionSeconds': 600,
            'durationSeconds': 2700,
            'percentage': 22.2,
            'watched': false,
          },
        },
      });

      expect(nextUp.state, NextUpState.continueWatching);
      expect(nextUp.episode.id, '42');
      expect(nextUp.episode.episodeCode, 'S02E05');
      expect(nextUp.episode.runtimeMinutes, 45);
      expect(nextUp.episode.files, hasLength(1));
      expect(nextUp.episode.progress?.positionSeconds, 600);
    });

    test('tolerates a missing files list and missing progress', () {
      final nextUp = ShowNextUp.fromJson({
        'progressState': 'start',
        'episode': {'id': '7', 'seasonNumber': 1, 'episodeNumber': 1},
      });

      expect(nextUp.state, NextUpState.start);
      expect(nextUp.episode.files, isEmpty);
      expect(nextUp.episode.progress, isNull);
      expect(nextUp.episode.runtimeMinutes, isNull);
    });
  });

  group('ShowDetail.nextUp', () {
    Map<String, dynamic> baseShow() => {
          'id': 's1',
          'title': 'Severance',
          'monitored': true,
          'seasonCount': 2,
          'episodeCount': 19,
          'isFavorite': false,
        };

    test('is null for a finished show, so the hero renders nothing', () {
      final show = ShowDetail.fromJson(baseShow());
      expect(show.nextUp, isNull);
    });

    test('parses when present', () {
      final show = ShowDetail.fromJson({
        ...baseShow(),
        'nextUp': {
          'progressState': 'next',
          'episode': {'id': '3', 'seasonNumber': 1, 'episodeNumber': 2},
        },
      });

      expect(show.nextUp?.state, NextUpState.next);
      expect(show.nextUp?.episode.episodeCode, 'S01E02');
    });
  });
}
