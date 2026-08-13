import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/models/watch_status.dart';

void main() {
  group('WatchStatus.fromJson', () {
    test('reads all three fields', () {
      final status = WatchStatus.fromJson(const {
        'watched': false,
        'percentage': 42.5,
        'unwatchedEpisodeCount': null,
      });

      expect(status.watched, isFalse);
      expect(status.percentage, 42.5);
      expect(status.unwatchedEpisodeCount, isNull);
    });

    test('tolerates a missing watched flag from an older server', () {
      final status = WatchStatus.fromJson(const {});

      expect(status.watched, isFalse);
      expect(status.percentage, isNull);
      expect(status.unwatchedEpisodeCount, isNull);
    });

    test('coerces an integer percentage to double', () {
      final status =
          WatchStatus.fromJson(const {'watched': false, 'percentage': 40});

      expect(status.percentage, 40.0);
    });
  });

  group('WatchStatus.fromProgress', () {
    test('carries watched and percentage across', () {
      const progress = Progress(
        positionSeconds: 30,
        durationSeconds: 100,
        percentage: 30.0,
        watched: false,
      );

      final status = WatchStatus.fromProgress(progress);

      expect(status.watched, isFalse);
      expect(status.percentage, 30.0);
      expect(status.unwatchedEpisodeCount, isNull);
    });
  });

  group('state getters', () {
    test('a container with unwatched episodes is a container', () {
      const status = WatchStatus(watched: false, unwatchedEpisodeCount: 5);

      expect(status.isUnwatchedContainer, isTrue);
      expect(status.isInProgress, isFalse);
      expect(status.isUntouched, isFalse);
    });

    test('a container with zero unwatched is not a container to badge', () {
      const status = WatchStatus(watched: false, unwatchedEpisodeCount: 0);

      expect(status.isUnwatchedContainer, isFalse);
      expect(status.isUntouched, isTrue);
    });

    test('a part-played movie is in progress and not untouched', () {
      const status = WatchStatus(watched: false, percentage: 40);

      expect(status.isInProgress, isTrue);
      expect(status.isUntouched, isFalse);
      expect(status.isUnwatchedContainer, isFalse);
    });

    test('a never-played movie is untouched', () {
      const status = WatchStatus(watched: false);

      expect(status.isUntouched, isTrue);
      expect(status.isInProgress, isFalse);
    });

    test('a zero percentage is untouched, not in progress', () {
      const status = WatchStatus(watched: false, percentage: 0);

      expect(status.isUntouched, isTrue);
      expect(status.isInProgress, isFalse);
    });

    test('a watched item is none of the three', () {
      const status = WatchStatus(watched: true, percentage: 100);

      expect(status.isUnwatchedContainer, isFalse);
      expect(status.isInProgress, isFalse);
      expect(status.isUntouched, isFalse);
    });
  });
}
