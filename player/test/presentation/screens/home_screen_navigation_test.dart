import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';
import 'package:player/presentation/screens/home_screen.dart';

void main() {
  group('playerRouteFor', () {
    test('routes a continue-watching movie to the movie player', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'm1',
        'type': 'movie',
        'title': 'Arrival',
        'progress': {
          'positionSeconds': 900,
          'durationSeconds': 6960,
          'percentage': 12.9,
          'watched': false,
        },
      });

      final route = playerRouteForContinueWatching(item, fileId: 'f2');

      expect(route, startsWith('/player/movie/m1?'));
      expect(route, contains('resume=900'));
      expect(route, isNot(contains('seasonNumber=')));
    });

    test('routes a continue-watching episode with its show context', () {
      final item = ContinueWatchingItem.fromJson({
        'id': 'e2',
        'type': 'episode',
        'title': 'Half Loop',
        'showId': 's1',
        'showTitle': 'Severance',
        'seasonNumber': 2,
        'episodeNumber': 6,
        'progress': {
          'positionSeconds': 120,
          'durationSeconds': 2700,
          'percentage': 4.4,
          'watched': false,
        },
      });

      final route = playerRouteForContinueWatching(item, fileId: 'f3');

      expect(route, startsWith('/player/episode/e2?'));
      expect(route, contains('showId=s1'));
      expect(route, contains('seasonNumber=2'));
      expect(route, contains('resume=120'));
    });

    testWidgets('a next-episode card starts from the beginning',
        (tester) async {
      final item = ContinueWatchingItem.fromJson({
        'id': 'ep-1',
        'type': 'episode',
        'title': 'Rhaenyra Triumphant',
        'state': 'next',
        'showId': 'show-1',
        'showTitle': 'House of the Dragon',
        'seasonNumber': 3,
        'episodeNumber': 3,
        'progress': {
          'positionSeconds': 0,
          'durationSeconds': 3600,
          'percentage': 0.0,
          'watched': false,
          'lastWatchedAt': null,
        },
        'files': <dynamic>[],
      });

      final route = playerRouteForContinueWatching(item, fileId: 'file-1');

      expect(route, isNot(contains('resume=')));
      expect(route, contains('/player/episode/ep-1'));
      expect(route, contains('showId=show-1'));
    });
  });
}
