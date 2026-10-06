import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/sources/item.dart';

const _source = SourceId('a:b:c');

ItemRef _ref(ItemKind kind, String id) =>
    ItemRef(sourceId: _source, kind: kind, externalId: id);

void main() {
  group('SourceTarget', () {
    test('names the item and the source that owns it', () {
      final target = SourceTarget(_ref(ItemKind.show, 'show-7'));
      expect(target.id, 'show-7');
      expect(target.kind, DetailKind.show);
      expect(target.ref.sourceId, _source);
    });

    test('targets with the same item are equal, across sources they are not',
        () {
      expect(SourceTarget(_ref(ItemKind.movie, 'm1')),
          SourceTarget(_ref(ItemKind.movie, 'm1')));
      expect(SourceTarget(_ref(ItemKind.movie, 'm1')),
          isNot(SourceTarget(_ref(ItemKind.show, 'm1'))));
      expect(
        SourceTarget(_ref(ItemKind.movie, 'm1')),
        isNot(const SourceTarget(ItemRef(
            sourceId: SourceId('d:e:f'),
            kind: ItemKind.movie,
            externalId: 'm1'))),
      );
    });
  });

  group('EpisodeView', () {
    EpisodeView episode({int? runtime, Progress? progress}) => EpisodeView(
          target: SourceTarget(_ref(ItemKind.episode, 'e1')),
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
          target: SourceTarget(_ref(ItemKind.movie, 'm1')),
          title: 'Meridian Drift',
          year: 2024,
          runtime: runtime,
          rating: rating,
          progress: progress,
        );

    test('display getters format the year, rating and runtime', () {
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

    test('watchedAtDisplay is empty with no progress row or no date', () {
      expect(movie().watchedAtDisplay, '');
      expect(
        movie(
          progress:
              const Progress(positionSeconds: 0, percentage: 0, watched: true),
        ).watchedAtDisplay,
        '',
      );
    });
  });

  group('formatWatchedAt', () {
    final now = DateTime(2026, 8, 4);

    test('returns empty for a null timestamp', () {
      expect(formatWatchedAt(null, now), '');
    });

    test('returns empty for an unparseable timestamp', () {
      expect(formatWatchedAt('not a date', now), '');
    });

    test('omits the year inside the current year', () {
      // Built from a local DateTime so the round-trip through toLocal()
      // cannot shift the day under a test runner in any timezone.
      final watchedAt = DateTime(2026, 8, 2, 12).toIso8601String();

      expect(formatWatchedAt(watchedAt, now), 'Aug 2');
    });

    test('includes the year outside the current year', () {
      final watchedAt = DateTime(2025, 8, 2, 12).toIso8601String();

      expect(formatWatchedAt(watchedAt, now), 'Aug 2, 2025');
    });

    test('parses the UTC form the server actually sends', () {
      // Asserts only that a Z-suffixed timestamp formats to something,
      // since the exact local day depends on the runner's timezone.
      expect(formatWatchedAt('2026-08-02T12:00:00Z', now), isNotEmpty);
    });
  });
}
