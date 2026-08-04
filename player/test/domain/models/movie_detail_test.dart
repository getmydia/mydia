import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/artwork.dart';
import 'package:player/domain/models/movie_detail.dart';
import 'package:player/domain/models/progress.dart';

MovieDetail _movie({Progress? progress, bool isFavorite = false}) {
  return MovieDetail(
    id: 'm-1',
    title: 'Blade Runner 2049',
    year: 2017,
    overview: 'Thirty years later.',
    runtime: 164,
    genres: const ['Sci-Fi'],
    monitored: true,
    artwork: const Artwork(),
    progress: progress,
    isFavorite: isFavorite,
  );
}

void main() {
  group('MovieDetail.copyWith', () {
    test('carries every untouched field through unchanged', () {
      final original = _movie();
      final copy = original.copyWith(isFavorite: true);

      expect(copy.id, original.id);
      expect(copy.title, original.title);
      expect(copy.year, original.year);
      expect(copy.overview, original.overview);
      expect(copy.runtime, original.runtime);
      expect(copy.genres, original.genres);
      expect(copy.monitored, original.monitored);
      expect(copy.artwork, same(original.artwork));
      expect(copy.files, original.files);
    });

    test('flips only isFavorite', () {
      final copy = _movie().copyWith(isFavorite: true);

      expect(copy.isFavorite, isTrue);
      expect(copy.progress, isNull);
    });

    test('sets progress when one is passed', () {
      const progress = Progress(
        positionSeconds: 60,
        percentage: 10,
        watched: false,
      );
      final copy = _movie().copyWith(progress: progress);

      expect(copy.progress, same(progress));
      expect(copy.isFavorite, isFalse);
    });

    test('clearProgress nulls progress and beats a passed progress', () {
      const existing = Progress(
        positionSeconds: 60,
        percentage: 10,
        watched: false,
      );
      final copy = _movie(progress: existing).copyWith(
        progress: const Progress(
          positionSeconds: 99,
          percentage: 50,
          watched: true,
        ),
        clearProgress: true,
      );

      expect(copy.progress, isNull);
    });
  });

  group('MovieDetail display gates', () {
    test('no progress row is neither watched nor resumable', () {
      final movie = _movie();

      expect(movie.isWatched, isFalse);
      expect(movie.hasResumableProgress, isFalse);
    });

    test('a watched row is watched and not resumable', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 600,
          percentage: 90,
          watched: true,
        ),
      );

      expect(movie.isWatched, isTrue);
      expect(movie.hasResumableProgress, isFalse);
    });

    test('a started unwatched row is resumable and not watched', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 600,
          percentage: 38,
          watched: false,
        ),
      );

      expect(movie.isWatched, isFalse);
      expect(movie.hasResumableProgress, isTrue);
    });

    test('a zero-percent unwatched row is not resumable', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 0,
          percentage: 0,
          watched: false,
        ),
      );

      expect(movie.hasResumableProgress, isFalse);
    });
  });

  group('MovieDetail.formatWatchedAt', () {
    final now = DateTime(2026, 8, 4);

    test('returns empty for a null timestamp', () {
      expect(MovieDetail.formatWatchedAt(null, now), '');
    });

    test('returns empty for an unparseable timestamp', () {
      expect(MovieDetail.formatWatchedAt('not a date', now), '');
    });

    test('omits the year inside the current year', () {
      // Built from a local DateTime so the round-trip through toLocal()
      // cannot shift the day under a test runner in any timezone.
      final watchedAt = DateTime(2026, 8, 2, 12).toIso8601String();

      expect(MovieDetail.formatWatchedAt(watchedAt, now), 'Aug 2');
    });

    test('includes the year outside the current year', () {
      final watchedAt = DateTime(2025, 8, 2, 12).toIso8601String();

      expect(MovieDetail.formatWatchedAt(watchedAt, now), 'Aug 2, 2025');
    });

    test('parses the UTC form the server actually sends', () {
      // Asserts only that a Z-suffixed timestamp formats to something,
      // since the exact local day depends on the runner's timezone.
      expect(
        MovieDetail.formatWatchedAt('2026-08-02T12:00:00Z', now),
        isNotEmpty,
      );
    });
  });

  group('MovieDetail.watchedAtDisplay', () {
    test('is empty when there is no progress row', () {
      expect(_movie().watchedAtDisplay, '');
    });

    test('is empty when the row has no lastWatchedAt', () {
      final movie = _movie(
        progress: const Progress(
          positionSeconds: 0,
          percentage: 0,
          watched: true,
        ),
      );

      expect(movie.watchedAtDisplay, '');
    });
  });
}
