import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

void main() {
  group('DownloadedMedia', () {
    group('type getter', () {
      test('returns movie for "movie" mediaType', () {
        final media = _createMedia(mediaType: 'movie');
        expect(media.type, equals(MediaType.movie));
      });

      test('returns episode for "episode" mediaType', () {
        final media = _createMedia(mediaType: 'episode');
        expect(media.type, equals(MediaType.episode));
      });

      test('returns movie for unknown mediaType', () {
        final media = _createMedia(mediaType: 'unknown');
        expect(media.type, equals(MediaType.movie));
      });

      test('returns movie for empty mediaType', () {
        final media = _createMedia(mediaType: '');
        expect(media.type, equals(MediaType.movie));
      });
    });

    group('fileSizeDisplay getter', () {
      test('formats bytes correctly', () {
        final media = _createMedia(fileSize: 500);
        expect(media.fileSizeDisplay, equals('500 B'));
      });

      test('formats kilobytes correctly', () {
        final media = _createMedia(fileSize: 1536);
        expect(media.fileSizeDisplay, equals('1.5 KB'));
      });

      test('formats megabytes correctly', () {
        final media = _createMedia(fileSize: 2097152);
        expect(media.fileSizeDisplay, equals('2.0 MB'));
      });

      test('formats gigabytes correctly', () {
        final media = _createMedia(fileSize: 5368709120);
        expect(media.fileSizeDisplay, equals('5.00 GB'));
      });

      test('formats 0 bytes correctly', () {
        final media = _createMedia(fileSize: 0);
        expect(media.fileSizeDisplay, equals('0 B'));
      });

      test('formats edge case at KB boundary', () {
        final media = _createMedia(fileSize: 1024);
        expect(media.fileSizeDisplay, equals('1.0 KB'));
      });

      test('formats edge case at MB boundary', () {
        final media = _createMedia(fileSize: 1024 * 1024);
        expect(media.fileSizeDisplay, equals('1.0 MB'));
      });

      test('formats edge case at GB boundary', () {
        final media = _createMedia(fileSize: 1024 * 1024 * 1024);
        expect(media.fileSizeDisplay, equals('1.00 GB'));
      });

      test('formats large GB values correctly', () {
        // 10 GB
        final media = _createMedia(fileSize: 10 * 1024 * 1024 * 1024);
        expect(media.fileSizeDisplay, equals('10.00 GB'));
      });
    });

    group('fromTask factory', () {
      test('transfers basic fields from DownloadTask', () {
        final now = DateTime.now();
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test Movie',
          quality: '1080p',
          progress: 1.0,
          status: 'completed',
          mediaType: 'movie',
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
          posterUrl: 'https://example.com/poster.jpg',
          createdAt: now.subtract(const Duration(hours: 1)),
          completedAt: now,
        );

        final media = DownloadedMedia.fromTask(task);

        expect(media.id, equals('task-123'));
        expect(media.mediaId, equals('media-456'));
        expect(media.title, equals('Test Movie'));
        expect(media.quality, equals('1080p'));
        expect(media.filePath, equals('/downloads/movie.mp4'));
        expect(media.fileSize, equals(1024000));
        expect(media.mediaType, equals('movie'));
        expect(media.posterUrl, equals('https://example.com/poster.jpg'));
        expect(media.downloadedAt, equals(now));
      });

      test('transfers metadata fields from DownloadTask', () {
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test Movie',
          quality: '1080p',
          createdAt: DateTime.now(),
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
          overview: 'An exciting movie about testing',
          runtime: 120,
          genres: ['Action', 'Drama', 'Sci-Fi'],
          rating: 8.5,
          backdropUrl: 'https://example.com/backdrop.jpg',
          year: 2024,
          contentRating: 'PG-13',
        );

        final media = DownloadedMedia.fromTask(task);

        expect(media.overview, equals('An exciting movie about testing'));
        expect(media.runtime, equals(120));
        expect(media.genres, equals(['Action', 'Drama', 'Sci-Fi']));
        expect(media.rating, equals(8.5));
        expect(media.backdropUrl, equals('https://example.com/backdrop.jpg'));
        expect(media.year, equals(2024));
        expect(media.contentRating, equals('PG-13'));
      });

      test('transfers episode-specific fields from DownloadTask', () {
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'episode-456',
          title: 'Pilot',
          quality: '720p',
          mediaType: 'episode',
          createdAt: DateTime.now(),
          filePath: '/downloads/episode.mp4',
          fileSize: 512000,
          seasonNumber: 1,
          episodeNumber: 1,
          showId: 'show-789',
          showTitle: 'Test Show',
          showPosterUrl: 'https://example.com/show-poster.jpg',
          thumbnailUrl: 'https://example.com/episode-thumb.jpg',
          airDate: '2024-01-15',
        );

        final media = DownloadedMedia.fromTask(task);

        expect(media.seasonNumber, equals(1));
        expect(media.episodeNumber, equals(1));
        expect(media.showId, equals('show-789'));
        expect(media.showTitle, equals('Test Show'));
        expect(
            media.showPosterUrl, equals('https://example.com/show-poster.jpg'));
        expect(media.thumbnailUrl,
            equals('https://example.com/episode-thumb.jpg'));
        expect(media.airDate, equals('2024-01-15'));
      });

      test('uses DateTime.now() when completedAt is null', () {
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test',
          quality: '1080p',
          createdAt: DateTime.now(),
          completedAt: null,
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
        );

        final before = DateTime.now();
        final media = DownloadedMedia.fromTask(task);
        final after = DateTime.now();

        expect(
            media.downloadedAt.isAfter(before) ||
                media.downloadedAt.isAtSameMomentAs(before),
            isTrue);
        expect(
            media.downloadedAt.isBefore(after) ||
                media.downloadedAt.isAtSameMomentAs(after),
            isTrue);
      });

      test('handles null genres from task', () {
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test',
          quality: '1080p',
          createdAt: DateTime.now(),
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
          genres: null,
        );

        final media = DownloadedMedia.fromTask(task);

        expect(media.genres, isEmpty);
      });

      test('handles empty genres from task', () {
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test',
          quality: '1080p',
          createdAt: DateTime.now(),
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
          genres: [],
        );

        final media = DownloadedMedia.fromTask(task);

        expect(media.genres, isEmpty);
      });
    });

    group('constructor defaults', () {
      test('defaults mediaType to "movie"', () {
        final media = DownloadedMedia(
          id: 'id',
          mediaId: 'mid',
          title: 'Title',
          quality: '1080p',
          filePath: '/path',
          fileSize: 1024,
          downloadedAt: DateTime.now(),
        );

        expect(media.mediaType, equals('movie'));
      });

      test('defaults genres to empty list', () {
        final media = DownloadedMedia(
          id: 'id',
          mediaId: 'mid',
          title: 'Title',
          quality: '1080p',
          filePath: '/path',
          fileSize: 1024,
          downloadedAt: DateTime.now(),
        );

        expect(media.genres, isEmpty);
      });
    });
  });
}

/// Helper function to create a [DownloadedMedia] with sensible defaults.
DownloadedMedia _createMedia({
  String id = 'test-id',
  String mediaId = 'media-id',
  String title = 'Test Title',
  String quality = '1080p',
  String filePath = '/downloads/test.mp4',
  int fileSize = 1024000,
  String mediaType = 'movie',
  String? posterUrl,
  DateTime? downloadedAt,
}) {
  return DownloadedMedia(
    id: id,
    mediaId: mediaId,
    title: title,
    quality: quality,
    filePath: filePath,
    fileSize: fileSize,
    mediaType: mediaType,
    posterUrl: posterUrl,
    downloadedAt: downloadedAt ?? DateTime.now(),
  );
}
