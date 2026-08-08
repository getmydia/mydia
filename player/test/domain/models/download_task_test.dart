import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/download.dart';

void main() {
  group('DownloadTask', () {
    group('downloadStatus getter', () {
      test('returns pending for "pending" status', () {
        final task = _createTask(status: 'pending');
        expect(task.downloadStatus, equals(DownloadStatus.pending));
      });

      test('returns downloading for "downloading" status', () {
        final task = _createTask(status: 'downloading');
        expect(task.downloadStatus, equals(DownloadStatus.downloading));
      });

      test('returns completed for "completed" status', () {
        final task = _createTask(status: 'completed');
        expect(task.downloadStatus, equals(DownloadStatus.completed));
      });

      test('returns failed for "failed" status', () {
        final task = _createTask(status: 'failed');
        expect(task.downloadStatus, equals(DownloadStatus.failed));
      });

      test('returns paused for "paused" status', () {
        final task = _createTask(status: 'paused');
        expect(task.downloadStatus, equals(DownloadStatus.paused));
      });

      test('returns cancelled for "cancelled" status', () {
        final task = _createTask(status: 'cancelled');
        expect(task.downloadStatus, equals(DownloadStatus.cancelled));
      });

      test('returns transcoding for "transcoding" status', () {
        final task = _createTask(status: 'transcoding');
        expect(task.downloadStatus, equals(DownloadStatus.transcoding));
      });

      test('returns queued for "queued" status', () {
        final task = _createTask(status: 'queued');
        expect(task.downloadStatus, equals(DownloadStatus.queued));
      });

      test('returns pending for unknown status', () {
        final task = _createTask(status: 'unknown_status');
        expect(task.downloadStatus, equals(DownloadStatus.pending));
      });
    });

    group('combinedProgress getter', () {
      test('returns progress for non-progressive downloads', () {
        final task = _createTask(
          progress: 0.75,
          isProgressive: false,
        );
        expect(task.combinedProgress, equals(0.75));
      });

      test('weights transcode and download progress for progressive downloads',
          () {
        // 30% transcode + 70% download
        final task = _createTask(
          isProgressive: true,
          transcodeProgress: 1.0, // 1.0 * 0.3 = 0.3
          downloadProgress: 0.5, // 0.5 * 0.7 = 0.35
        );
        // Total: 0.3 + 0.35 = 0.65
        expect(task.combinedProgress, closeTo(0.65, 0.001));
      });

      test('returns 0.0 when both progress values are 0', () {
        final task = _createTask(
          isProgressive: true,
          transcodeProgress: 0.0,
          downloadProgress: 0.0,
        );
        expect(task.combinedProgress, equals(0.0));
      });

      test('returns 1.0 when both progress values are complete', () {
        final task = _createTask(
          isProgressive: true,
          transcodeProgress: 1.0,
          downloadProgress: 1.0,
        );
        expect(task.combinedProgress, equals(1.0));
      });

      test('prioritizes download progress (70% weight)', () {
        final taskHighDownload = _createTask(
          isProgressive: true,
          transcodeProgress: 0.0,
          downloadProgress: 1.0,
        );
        expect(taskHighDownload.combinedProgress, equals(0.7));

        final taskHighTranscode = _createTask(
          isProgressive: true,
          transcodeProgress: 1.0,
          downloadProgress: 0.0,
        );
        expect(taskHighTranscode.combinedProgress, equals(0.3));
      });
    });

    group('statusDisplay getter', () {
      group('non-progressive downloads', () {
        test('returns status string directly', () {
          final task = _createTask(
            status: 'downloading',
            isProgressive: false,
          );
          expect(task.statusDisplay, equals('downloading'));
        });
      });

      group('progressive downloads', () {
        test('shows preparing percentage for transcoding status', () {
          final task = _createTask(
            status: 'transcoding',
            isProgressive: true,
            transcodeProgress: 0.456,
          );
          expect(task.statusDisplay, equals('Preparing 46%'));
        });

        test('shows "Preparing & Downloading" when transcoding not complete',
            () {
          final task = _createTask(
            status: 'downloading',
            isProgressive: true,
            transcodeProgress: 0.8,
            downloadProgress: 0.2,
          );
          expect(task.statusDisplay, equals('Preparing & Downloading'));
        });

        test(
            'shows "Starting Download..." when transcode complete but download at 0',
            () {
          final task = _createTask(
            status: 'downloading',
            isProgressive: true,
            transcodeProgress: 1.0,
            downloadProgress: 0.0,
          );
          expect(task.statusDisplay, equals('Starting Download...'));
        });

        test('shows downloading percentage when transcode complete', () {
          final task = _createTask(
            status: 'downloading',
            isProgressive: true,
            transcodeProgress: 1.0,
            downloadProgress: 0.789,
          );
          expect(task.statusDisplay, equals('Downloading 79%'));
        });

        test('shows "Completed" for completed status', () {
          final task = _createTask(
            status: 'completed',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Completed'));
        });

        test('shows "Failed" for failed status', () {
          final task = _createTask(
            status: 'failed',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Failed'));
        });

        test('shows "Paused" for paused status', () {
          final task = _createTask(
            status: 'paused',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Paused'));
        });

        test('shows "Cancelled" for cancelled status', () {
          final task = _createTask(
            status: 'cancelled',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Cancelled'));
        });

        test('shows "Pending" for pending status', () {
          final task = _createTask(
            status: 'pending',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Pending'));
        });

        test('shows "Queued" for queued status', () {
          final task = _createTask(
            status: 'queued',
            isProgressive: true,
          );
          expect(task.statusDisplay, equals('Queued'));
        });
      });
    });

    group('type getter', () {
      test('returns movie for "movie" mediaType', () {
        final task = _createTask(mediaType: 'movie');
        expect(task.type, equals(MediaType.movie));
      });

      test('returns episode for "episode" mediaType', () {
        final task = _createTask(mediaType: 'episode');
        expect(task.type, equals(MediaType.episode));
      });

      test('returns movie for unknown mediaType', () {
        final task = _createTask(mediaType: 'unknown');
        expect(task.type, equals(MediaType.movie));
      });
    });

    group('fileSizeDisplay getter', () {
      test('returns "Unknown size" when fileSize is null', () {
        final task = _createTask(fileSize: null);
        expect(task.fileSizeDisplay, equals('Unknown size'));
      });

      test('formats bytes correctly', () {
        final task = _createTask(fileSize: 500);
        expect(task.fileSizeDisplay, equals('500 B'));
      });

      test('formats kilobytes correctly', () {
        final task = _createTask(fileSize: 1536);
        expect(task.fileSizeDisplay, equals('1.5 KB'));
      });

      test('formats megabytes correctly', () {
        final task = _createTask(fileSize: 2097152);
        expect(task.fileSizeDisplay, equals('2.0 MB'));
      });

      test('formats gigabytes correctly', () {
        final task = _createTask(fileSize: 5368709120);
        expect(task.fileSizeDisplay, equals('5.00 GB'));
      });

      test('formats edge case at KB boundary', () {
        final task = _createTask(fileSize: 1024);
        expect(task.fileSizeDisplay, equals('1.0 KB'));
      });

      test('formats edge case at MB boundary', () {
        final task = _createTask(fileSize: 1024 * 1024);
        expect(task.fileSizeDisplay, equals('1.0 MB'));
      });

      test('formats edge case at GB boundary', () {
        final task = _createTask(fileSize: 1024 * 1024 * 1024);
        expect(task.fileSizeDisplay, equals('1.00 GB'));
      });
    });

    group('progressDisplay getter', () {
      test('formats 0% correctly', () {
        final task = _createTask(progress: 0.0);
        expect(task.progressDisplay, equals('0%'));
      });

      test('formats 100% correctly', () {
        final task = _createTask(progress: 1.0);
        expect(task.progressDisplay, equals('100%'));
      });

      test('formats partial progress correctly', () {
        final task = _createTask(progress: 0.756);
        expect(task.progressDisplay, equals('76%'));
      });

      test('rounds down to nearest integer', () {
        final task = _createTask(progress: 0.499);
        expect(task.progressDisplay, equals('50%'));
      });
    });

    group('copyWith', () {
      test('preserves all fields when no arguments provided', () {
        final now = DateTime.now();
        final task = DownloadTask(
          id: 'task-123',
          mediaId: 'media-456',
          title: 'Test Movie',
          quality: '1080p',
          progress: 0.5,
          status: 'downloading',
          mediaType: 'movie',
          filePath: '/downloads/movie.mp4',
          fileSize: 1024000,
          downloadUrl: 'https://example.com/download',
          posterUrl: 'https://example.com/poster.jpg',
          error: null,
          createdAt: now,
          completedAt: null,
          transcodeJobId: 'job-789',
          transcodeProgress: 0.8,
          downloadProgress: 0.3,
          isProgressive: true,
          downloadedBytes: 512000,
          overview: 'A test movie',
          runtime: 120,
          genres: ['Action', 'Drama'],
          rating: 8.5,
          backdropUrl: 'https://example.com/backdrop.jpg',
          year: 2024,
          contentRating: 'PG-13',
          seasonNumber: null,
          episodeNumber: null,
          showId: null,
          showTitle: null,
          showPosterUrl: null,
          thumbnailUrl: 'https://example.com/thumb.jpg',
          airDate: null,
        );

        final copy = task.copyWith();

        expect(copy.id, equals(task.id));
        expect(copy.mediaId, equals(task.mediaId));
        expect(copy.title, equals(task.title));
        expect(copy.quality, equals(task.quality));
        expect(copy.progress, equals(task.progress));
        expect(copy.status, equals(task.status));
        expect(copy.mediaType, equals(task.mediaType));
        expect(copy.filePath, equals(task.filePath));
        expect(copy.fileSize, equals(task.fileSize));
        expect(copy.downloadUrl, equals(task.downloadUrl));
        expect(copy.posterUrl, equals(task.posterUrl));
        expect(copy.error, equals(task.error));
        expect(copy.createdAt, equals(task.createdAt));
        expect(copy.completedAt, equals(task.completedAt));
        expect(copy.transcodeJobId, equals(task.transcodeJobId));
        expect(copy.transcodeProgress, equals(task.transcodeProgress));
        expect(copy.downloadProgress, equals(task.downloadProgress));
        expect(copy.isProgressive, equals(task.isProgressive));
        expect(copy.downloadedBytes, equals(task.downloadedBytes));
        expect(copy.overview, equals(task.overview));
        expect(copy.runtime, equals(task.runtime));
        expect(copy.genres, equals(task.genres));
        expect(copy.rating, equals(task.rating));
        expect(copy.backdropUrl, equals(task.backdropUrl));
        expect(copy.year, equals(task.year));
        expect(copy.contentRating, equals(task.contentRating));
        expect(copy.seasonNumber, equals(task.seasonNumber));
        expect(copy.episodeNumber, equals(task.episodeNumber));
        expect(copy.showId, equals(task.showId));
        expect(copy.showTitle, equals(task.showTitle));
        expect(copy.showPosterUrl, equals(task.showPosterUrl));
        expect(copy.thumbnailUrl, equals(task.thumbnailUrl));
        expect(copy.airDate, equals(task.airDate));
      });

      test('updates specified fields', () {
        final task = _createTask(
          status: 'pending',
          progress: 0.0,
        );

        final updated = task.copyWith(
          status: 'downloading',
          progress: 0.5,
        );

        expect(updated.status, equals('downloading'));
        expect(updated.progress, equals(0.5));
        expect(updated.id, equals(task.id));
        expect(updated.title, equals(task.title));
      });

      test('allows updating progress fields independently', () {
        final task = _createTask(
          isProgressive: true,
          transcodeProgress: 0.5,
          downloadProgress: 0.2,
        );

        final updated = task.copyWith(downloadProgress: 0.8);

        expect(updated.transcodeProgress, equals(0.5));
        expect(updated.downloadProgress, equals(0.8));
      });
    });

    group('episodeCode', () {
      test('pads season and episode to two digits', () {
        final task = DownloadTask(
          id: 't1',
          mediaId: 'm1',
          title: 'Pilot',
          quality: '1080p',
          createdAt: DateTime(2026, 1, 1),
          seasonNumber: 1,
          episodeNumber: 3,
        );

        expect(task.episodeCode, 'S01E03');
      });

      test('renders question marks when the numbers are missing', () {
        final task = DownloadTask(
          id: 't1',
          mediaId: 'm1',
          title: 'A Movie',
          quality: '1080p',
          createdAt: DateTime(2026, 1, 1),
        );

        expect(task.episodeCode, 'S??E??');
      });
    });
  });
}

/// Helper function to create a [DownloadTask] with sensible defaults.
DownloadTask _createTask({
  String id = 'test-id',
  String mediaId = 'media-id',
  String title = 'Test Title',
  String quality = '1080p',
  double progress = 0.0,
  String status = 'pending',
  String mediaType = 'movie',
  String? filePath,
  int? fileSize,
  String? downloadUrl,
  String? posterUrl,
  String? error,
  DateTime? createdAt,
  DateTime? completedAt,
  String? transcodeJobId,
  double transcodeProgress = 0.0,
  double downloadProgress = 0.0,
  bool isProgressive = false,
  int? downloadedBytes,
}) {
  return DownloadTask(
    id: id,
    mediaId: mediaId,
    title: title,
    quality: quality,
    progress: progress,
    status: status,
    mediaType: mediaType,
    filePath: filePath,
    fileSize: fileSize,
    downloadUrl: downloadUrl,
    posterUrl: posterUrl,
    error: error,
    createdAt: createdAt ?? DateTime.now(),
    completedAt: completedAt,
    transcodeJobId: transcodeJobId,
    transcodeProgress: transcodeProgress,
    downloadProgress: downloadProgress,
    isProgressive: isProgressive,
    downloadedBytes: downloadedBytes,
  );
}
