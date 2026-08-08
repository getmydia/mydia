import 'package:hive_ce/hive.dart';

part 'download.g.dart';

enum DownloadStatus {
  pending,
  downloading,
  completed,
  failed,
  paused,
  cancelled,

  /// Transcoding in progress on server
  transcoding,

  /// Queued waiting for download slot
  queued,
}

enum MediaType {
  movie,
  episode,
}

@HiveType(typeId: 0)
class DownloadTask {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mediaId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String quality;

  @HiveField(4)
  final double progress;

  @HiveField(5)
  final String status;

  @HiveField(6)
  final String mediaType;

  @HiveField(7)
  final String? filePath;

  @HiveField(8)
  final int? fileSize;

  @HiveField(9)
  final String? downloadUrl;

  @HiveField(10)
  final String? posterUrl;

  @HiveField(11)
  final String? error;

  @HiveField(12)
  final DateTime createdAt;

  @HiveField(13)
  final DateTime? completedAt;

  // Progressive download fields
  @HiveField(14)
  final String? transcodeJobId;

  @HiveField(15)
  final double transcodeProgress;

  @HiveField(16)
  final double downloadProgress;

  @HiveField(17)
  final bool isProgressive;

  @HiveField(18)
  final int? downloadedBytes;

  // NEW: Metadata fields
  @HiveField(19)
  final String? overview;

  @HiveField(20)
  final int? runtime;

  @HiveField(21)
  final List<String>? genres;

  @HiveField(22)
  final double? rating;

  @HiveField(23)
  final String? backdropUrl;

  @HiveField(24)
  final int? year;

  @HiveField(25)
  final String? contentRating;

  @HiveField(26)
  final int? seasonNumber;

  @HiveField(27)
  final int? episodeNumber;

  @HiveField(28)
  final String? showId;

  @HiveField(29)
  final String? showTitle;

  @HiveField(30)
  final String? showPosterUrl;

  @HiveField(31)
  final String? thumbnailUrl;

  @HiveField(32)
  final String? airDate;

  const DownloadTask({
    required this.id,
    required this.mediaId,
    required this.title,
    required this.quality,
    this.progress = 0.0,
    this.status = 'pending',
    this.mediaType = 'movie',
    this.filePath,
    this.fileSize,
    this.downloadUrl,
    this.posterUrl,
    this.error,
    required this.createdAt,
    this.completedAt,
    // Progressive download fields
    this.transcodeJobId,
    this.transcodeProgress = 0.0,
    this.downloadProgress = 0.0,
    this.isProgressive = false,
    this.downloadedBytes,
    // Metadata fields
    this.overview,
    this.runtime,
    this.genres,
    this.rating,
    this.backdropUrl,
    this.year,
    this.contentRating,
    this.seasonNumber,
    this.episodeNumber,
    this.showId,
    this.showTitle,
    this.showPosterUrl,
    this.thumbnailUrl,
    this.airDate,
  });

  DownloadStatus get downloadStatus {
    switch (status) {
      case 'pending':
        return DownloadStatus.pending;
      case 'downloading':
        return DownloadStatus.downloading;
      case 'completed':
        return DownloadStatus.completed;
      case 'failed':
        return DownloadStatus.failed;
      case 'paused':
        return DownloadStatus.paused;
      case 'cancelled':
        return DownloadStatus.cancelled;
      case 'transcoding':
        return DownloadStatus.transcoding;
      case 'queued':
        return DownloadStatus.queued;
      default:
        return DownloadStatus.pending;
    }
  }

  /// Combined progress for progressive downloads.
  /// For progressive downloads, this weights transcode and download progress.
  double get combinedProgress {
    if (!isProgressive) {
      return progress;
    }
    // Weight: 30% transcode, 70% download (download is the slower operation)
    return (transcodeProgress * 0.3) + (downloadProgress * 0.7);
  }

  /// Status display text for progressive downloads.
  String get statusDisplay {
    if (!isProgressive) {
      return status;
    }

    switch (downloadStatus) {
      case DownloadStatus.transcoding:
        return 'Preparing ${(transcodeProgress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.downloading:
        if (transcodeProgress < 1.0) {
          return 'Preparing & Downloading';
        }
        if (downloadProgress <= 0.0) {
          return 'Starting Download...';
        }
        return 'Downloading ${(downloadProgress * 100).toStringAsFixed(0)}%';
      case DownloadStatus.completed:
        return 'Completed';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.cancelled:
        return 'Cancelled';
      case DownloadStatus.pending:
        return 'Pending';
      case DownloadStatus.queued:
        return 'Queued';
    }
  }

  MediaType get type {
    return mediaType == 'episode' ? MediaType.episode : MediaType.movie;
  }

  DownloadTask copyWith({
    String? id,
    String? mediaId,
    String? title,
    String? quality,
    double? progress,
    String? status,
    String? mediaType,
    String? filePath,
    int? fileSize,
    String? downloadUrl,
    String? posterUrl,
    String? error,
    DateTime? createdAt,
    DateTime? completedAt,
    String? transcodeJobId,
    double? transcodeProgress,
    double? downloadProgress,
    bool? isProgressive,
    int? downloadedBytes,
    String? overview,
    int? runtime,
    List<String>? genres,
    double? rating,
    String? backdropUrl,
    int? year,
    String? contentRating,
    int? seasonNumber,
    int? episodeNumber,
    String? showId,
    String? showTitle,
    String? showPosterUrl,
    String? thumbnailUrl,
    String? airDate,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      mediaId: mediaId ?? this.mediaId,
      title: title ?? this.title,
      quality: quality ?? this.quality,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      mediaType: mediaType ?? this.mediaType,
      filePath: filePath ?? this.filePath,
      fileSize: fileSize ?? this.fileSize,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      posterUrl: posterUrl ?? this.posterUrl,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
      transcodeJobId: transcodeJobId ?? this.transcodeJobId,
      transcodeProgress: transcodeProgress ?? this.transcodeProgress,
      downloadProgress: downloadProgress ?? this.downloadProgress,
      isProgressive: isProgressive ?? this.isProgressive,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      overview: overview ?? this.overview,
      runtime: runtime ?? this.runtime,
      genres: genres ?? this.genres,
      rating: rating ?? this.rating,
      backdropUrl: backdropUrl ?? this.backdropUrl,
      year: year ?? this.year,
      contentRating: contentRating ?? this.contentRating,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      showId: showId ?? this.showId,
      showTitle: showTitle ?? this.showTitle,
      showPosterUrl: showPosterUrl ?? this.showPosterUrl,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      airDate: airDate ?? this.airDate,
    );
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// e.g. "S01E03". Renders "S??E??" when the numbers are absent, which is
  /// what a movie or an unmatched file looks like.
  String get episodeCode =>
      'S${seasonNumber?.toString().padLeft(2, '0') ?? '??'}'
      'E${episodeNumber?.toString().padLeft(2, '0') ?? '??'}';

  String get fileSizeDisplay {
    if (fileSize == null) return 'Unknown size';
    return formatBytes(fileSize!);
  }

  /// Returns e.g. "245.0 MB / 1.2 GB" or null if data is unavailable.
  /// Falls back to estimating bytes from progress * fileSize.
  String? get progressBytesDisplay {
    final bytes = downloadedBytes ??
        (fileSize != null && fileSize! > 0 && progress > 0
            ? (progress * fileSize!).round()
            : null);
    if (bytes == null || bytes <= 0) return null;
    final downloaded = formatBytes(bytes);
    if (fileSize != null && fileSize! > 0) {
      return '$downloaded / ${formatBytes(fileSize!)}';
    }
    return downloaded;
  }

  String get progressDisplay {
    return '${(progress * 100).toStringAsFixed(0)}%';
  }
}

@HiveType(typeId: 1)
class DownloadedMedia {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String mediaId;

  @HiveField(2)
  final String title;

  @HiveField(3)
  final String quality;

  @HiveField(4)
  final String filePath;

  @HiveField(5)
  final int fileSize;

  @HiveField(6)
  final String mediaType;

  @HiveField(7)
  final String? posterUrl;

  @HiveField(8)
  final DateTime downloadedAt;

  // NEW: Common metadata
  @HiveField(9)
  final String? overview;

  @HiveField(10)
  final int? runtime;

  @HiveField(11)
  final List<String> genres;

  @HiveField(12)
  final double? rating;

  @HiveField(13)
  final String? backdropUrl;

  // NEW: Movie-specific
  @HiveField(14)
  final int? year;

  @HiveField(15)
  final String? contentRating;

  // NEW: Episode-specific
  @HiveField(16)
  final int? seasonNumber;

  @HiveField(17)
  final int? episodeNumber;

  @HiveField(18)
  final String? showId;

  @HiveField(19)
  final String? showTitle;

  @HiveField(20)
  final String? showPosterUrl;

  @HiveField(21)
  final String? thumbnailUrl;

  @HiveField(22)
  final String? airDate;

  const DownloadedMedia({
    required this.id,
    required this.mediaId,
    required this.title,
    required this.quality,
    required this.filePath,
    required this.fileSize,
    this.mediaType = 'movie',
    this.posterUrl,
    required this.downloadedAt,
    this.overview,
    this.runtime,
    this.genres = const [],
    this.rating,
    this.backdropUrl,
    this.year,
    this.contentRating,
    this.seasonNumber,
    this.episodeNumber,
    this.showId,
    this.showTitle,
    this.showPosterUrl,
    this.thumbnailUrl,
    this.airDate,
  });

  MediaType get type {
    return mediaType == 'episode' ? MediaType.episode : MediaType.movie;
  }

  /// e.g. "S01E03". Renders "S??E??" when the numbers are absent, which is
  /// what a movie or an unmatched file looks like.
  String get episodeCode =>
      'S${seasonNumber?.toString().padLeft(2, '0') ?? '??'}'
      'E${episodeNumber?.toString().padLeft(2, '0') ?? '??'}';

  String get fileSizeDisplay => DownloadTask.formatBytes(fileSize);

  factory DownloadedMedia.fromTask(DownloadTask task) {
    return DownloadedMedia(
      id: task.id,
      mediaId: task.mediaId,
      title: task.title,
      quality: task.quality,
      filePath: task.filePath!,
      fileSize: task.fileSize!,
      mediaType: task.mediaType,
      posterUrl: task.posterUrl,
      downloadedAt: task.completedAt ?? DateTime.now(),
      overview: task.overview,
      runtime: task.runtime,
      genres: task.genres ?? [],
      rating: task.rating,
      backdropUrl: task.backdropUrl,
      year: task.year,
      contentRating: task.contentRating,
      seasonNumber: task.seasonNumber,
      episodeNumber: task.episodeNumber,
      showId: task.showId,
      showTitle: task.showTitle,
      showPosterUrl: task.showPosterUrl,
      thumbnailUrl: task.thumbnailUrl,
      airDate: task.airDate,
    );
  }
}
