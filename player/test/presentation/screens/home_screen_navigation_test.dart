import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/continue_watching_item.dart';
import 'package:player/domain/models/up_next_item.dart';
import 'package:player/presentation/screens/home_screen.dart';

void main() {
  group('playerRouteFor', () {
    test('builds an episode route with resume for a continue item', () {
      final item = UpNextItem.fromJson({
        'progressState': 'continue',
        'episode': {
          'id': 'e1',
          'seasonNumber': 2,
          'episodeNumber': 5,
          'title': 'Woe\'s Hollow',
          'hasFile': true,
          'progress': {
            'positionSeconds': 600,
            'durationSeconds': 2700,
            'percentage': 22.2,
            'watched': false,
          },
        },
        'show': {'id': 's1', 'title': 'Severance'},
      });

      final route = playerRouteForUpNext(item, fileId: 'f1');

      expect(route, startsWith('/player/episode/e1?'));
      expect(route, contains('fileId=f1'));
      expect(route, contains('showId=s1'));
      expect(route, contains('seasonNumber=2'));
      expect(route, contains('resume=600'));
    });

    test('omits resume for a start item', () {
      final item = UpNextItem.fromJson({
        'progressState': 'start',
        'episode': {
          'id': 'e1',
          'seasonNumber': 1,
          'episodeNumber': 1,
          'title': 'Good News About Hell',
          'hasFile': true,
        },
        'show': {'id': 's1', 'title': 'Severance'},
      });

      expect(
          playerRouteForUpNext(item, fileId: 'f1'), isNot(contains('resume=')));
    });

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
  });
}
