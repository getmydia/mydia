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

    test('runtimeDuration carries the minutes as a Duration', () {
      expect(episode(runtime: 45).runtimeDuration, const Duration(minutes: 45));
      expect(episode(runtime: 90).runtimeDuration, const Duration(minutes: 90));
      expect(episode().runtimeDuration, isNull);
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
      expect(m.runtimeDuration, const Duration(minutes: 146));
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

    test('lastWatchedAt is null with no progress row or no date', () {
      expect(movie().lastWatchedAt, isNull);
      expect(
        movie(
          progress:
              const Progress(positionSeconds: 0, percentage: 0, watched: true),
        ).lastWatchedAt,
        isNull,
      );
    });

    test('lastWatchedAt is null for an unparseable timestamp', () {
      expect(
        movie(
          progress: const Progress(
            positionSeconds: 0,
            percentage: 0,
            watched: true,
            lastWatchedAt: 'not a date',
          ),
        ).lastWatchedAt,
        isNull,
      );
    });

    test('lastWatchedAt parses the UTC form the server sends', () {
      expect(
        movie(
          progress: const Progress(
            positionSeconds: 0,
            percentage: 0,
            watched: true,
            lastWatchedAt: '2026-08-02T12:00:00Z',
          ),
        ).lastWatchedAt,
        DateTime.utc(2026, 8, 2, 12),
      );
    });
  });
}
