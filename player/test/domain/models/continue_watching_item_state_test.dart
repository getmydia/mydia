import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';

Map<String, dynamic> episodeJson({
  String? state,
  int positionSeconds = 0,
}) {
  return {
    'id': 'ep-1',
    'type': 'episode',
    'title': 'Rhaenyra Triumphant',
    'state': state,
    'showId': 'show-1',
    'showTitle': 'House of the Dragon',
    'seasonNumber': 3,
    'episodeNumber': 3,
    'progress': {
      'positionSeconds': positionSeconds,
      'durationSeconds': 3600,
      'percentage': 0.0,
      'watched': false,
      'lastWatchedAt': null,
    },
    'files': <dynamic>[],
  };
}

void main() {
  group('ContinueWatchingItem.state', () {
    test('parses the state field', () {
      final item = ContinueWatchingItem.fromJson(episodeJson(state: 'next'));

      expect(item.state, 'next');
      expect(item.isNext, isTrue);
    });

    test('a continue item is not next', () {
      final item = ContinueWatchingItem.fromJson(
        episodeJson(state: 'continue', positionSeconds: 600),
      );

      expect(item.isNext, isFalse);
    });

    test('infers next from a zero position when state is absent', () {
      // The legacy query path against an older server omits `state`.
      final item = ContinueWatchingItem.fromJson(episodeJson());

      expect(item.state, isNull);
      expect(item.isNext, isTrue);
    });

    test('does not infer next when a saved position exists', () {
      final item = ContinueWatchingItem.fromJson(
        episodeJson(positionSeconds: 600),
      );

      expect(item.isNext, isFalse);
    });
  });

  group('ContinueWatchingItem.railSubtitle', () {
    test('a next episode is labelled', () {
      final item = ContinueWatchingItem.fromJson(episodeJson(state: 'next'));

      expect(item.railSubtitle, 'Next up · S03E03');
    });

    test('a continue episode shows the show and code', () {
      final item = ContinueWatchingItem.fromJson(
        episodeJson(state: 'continue', positionSeconds: 600),
      );

      expect(item.railSubtitle, 'House of the Dragon · S03E03');
    });

    test('a movie has no subtitle', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'movie-1',
        'type': 'movie',
        'title': 'Some Movie',
        'state': 'continue',
        'progress': {
          'positionSeconds': 600,
          'durationSeconds': 7200,
          'percentage': 8.3,
          'watched': false,
          'lastWatchedAt': null,
        },
        'files': <dynamic>[],
      });

      expect(item.railSubtitle, isNull);
    });
  });
}
