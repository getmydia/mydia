import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/progress.dart';

void main() {
  group('MydiaTarget', () {
    test('key is the bare Mydia id, so existing per-show providers match', () {
      expect(const MydiaTarget(DetailKind.show, 'show-7').key, 'show-7');
    });

    test('targets with the same kind and id are equal', () {
      expect(const MydiaTarget(DetailKind.movie, 'm1'),
          const MydiaTarget(DetailKind.movie, 'm1'));
      expect(const MydiaTarget(DetailKind.movie, 'm1'),
          isNot(const MydiaTarget(DetailKind.show, 'm1')));
    });
  });

  group('EpisodeView', () {
    EpisodeView episode({int? runtime, Progress? progress}) => EpisodeView(
          target: const MydiaTarget(DetailKind.episode, 'e1'),
          showTitle: 'Invented Series',
          seasonNumber: 2,
          episodeNumber: 5,
          title: 'The Glass Orchard',
          runtime: runtime,
          progress: progress,
        );

    test('episodeCode pads season and episode', () {
      expect(episode().episodeCode, 'S02E05');
    });

    test('runtimeDisplay formats minutes and hours', () {
      expect(episode(runtime: 45).runtimeDisplay, '45m');
      expect(episode(runtime: 90).runtimeDisplay, '1h 30m');
      expect(episode().runtimeDisplay, '');
    });

    test('watched reads the progress row', () {
      expect(episode().watched, isFalse);
      expect(
        episode(
          progress: const Progress(
              positionSeconds: 0, percentage: 100, watched: true),
        ).watched,
        isTrue,
      );
    });
  });

  group('MovieView', () {
    MovieView movie({Progress? progress, double? rating, int? runtime}) =>
        MovieView(
          target: const MydiaTarget(DetailKind.movie, 'm1'),
          title: 'Meridian Drift',
          year: 2024,
          runtime: runtime,
          rating: rating,
          progress: progress,
        );

    test('display getters match MovieDetail', () {
      final m = movie(rating: 8.14, runtime: 146);
      expect(m.yearDisplay, '2024');
      expect(m.ratingDisplay, '8.1');
      expect(m.runtimeDisplay, '2h 26m');
    });

    test('hasResumableProgress needs unwatched partial progress', () {
      expect(movie().hasResumableProgress, isFalse);
      expect(
        movie(
          progress: const Progress(
              positionSeconds: 60, percentage: 10, watched: false),
        ).hasResumableProgress,
        isTrue,
      );
    });
  });
}
