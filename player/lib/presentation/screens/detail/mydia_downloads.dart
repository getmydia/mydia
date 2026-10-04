/// Progressive-download flows for Mydia items: quality dialog, then
/// `startProgressiveDownload` through the unified download job service. Shared
/// by the movie, show and episode screens and the episode rail download button.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_job_providers.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/download_service.dart' show DownloadService;
import '../../../domain/models/download.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/models/episode_detail.dart';
import '../../../domain/models/movie_detail.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// The server-job callbacks `startProgressiveDownload` takes, bound to one
/// content item and resolution.
class _JobCallbacks {
  const _JobCallbacks({
    required this.getDownloadUrl,
    required this.prepareDownload,
    required this.getJobStatus,
    required this.cancelJob,
  });

  final Future<String> Function(String jobId) getDownloadUrl;
  final Future<({String jobId, String status, double progress, int? fileSize})>
      Function() prepareDownload;
  final Future<({String status, double progress, int? fileSize, String? error})>
      Function(String jobId) getJobStatus;
  final Future<void> Function(String jobId) cancelJob;
}

/// Calls `manager.startProgressiveDownload` with the metadata fields that
/// differ per content type; the shared job callbacks come in as `jobs`.
typedef _StartDownload = Future<void> Function(
  DownloadService manager,
  String resolution,
  _JobCallbacks jobs,
);

/// The plumbing every progressive download shares: already-downloaded toast,
/// quality dialog, service and manager lookup, job callbacks, and the
/// started/failed toasts. [start] supplies the per-type metadata.
///
/// [hasFiles] is checked after the already-downloaded toast, so an episode
/// without files still reports "Already downloaded" but never opens the dialog.
Future<void> _runProgressiveDownload(
  BuildContext context,
  WidgetRef ref, {
  required String contentType,
  required String mediaId,
  required String dialogTitle,
  required _StartDownload start,
  bool hasFiles = true,
}) async {
  final isDownloaded =
      ref.read(isMediaDownloadedProvider(mediaId)).value ?? false;

  if (isDownloaded) {
    if (context.mounted) {
      showToast(context, 'Already downloaded');
    }
    return;
  }
  if (!hasFiles) return;

  final selectedResolution = await showQualityDownloadDialog(
    context,
    contentType: contentType,
    contentId: mediaId,
    title: dialogTitle,
  );
  if (selectedResolution == null || !context.mounted) return;

  final downloadService = ref.read(unifiedDownloadJobServiceProvider);
  final downloadManager = await ref.read(downloadManagerProvider.future);
  if (downloadService == null) return;

  final jobs = _JobCallbacks(
    getDownloadUrl: (jobId) async {
      return await downloadService.getDownloadUrl(jobId);
    },
    prepareDownload: () async {
      final status = await downloadService.prepareDownload(
        contentType: contentType,
        id: mediaId,
        resolution: selectedResolution,
      );
      return (
        jobId: status.jobId,
        status: status.status.name,
        progress: status.progress,
        fileSize: status.currentFileSize,
      );
    },
    getJobStatus: (jobId) async {
      final status = await downloadService.getJobStatus(jobId);
      return (
        status: status.status.name,
        progress: status.progress,
        fileSize: status.currentFileSize,
        error: status.error,
      );
    },
    cancelJob: (jobId) async {
      await downloadService.cancelJob(jobId);
    },
  );

  try {
    await start(downloadManager, selectedResolution, jobs);

    if (context.mounted) {
      showToast(context, 'Download started', kind: ToastKind.success);
    }
  } catch (e) {
    if (context.mounted) {
      showToast(
        context,
        'Failed to start download: $e',
        kind: ToastKind.error,
      );
    }
  }
}

/// Starts a progressive download of a Mydia movie.
Future<void> startMydiaMovieDownload(
  BuildContext context,
  WidgetRef ref,
  MovieDetail movie,
) async {
  if (movie.files.isEmpty) return;

  return _runProgressiveDownload(
    context,
    ref,
    contentType: 'movie',
    mediaId: movie.id,
    dialogTitle: movie.title,
    start: (manager, resolution, jobs) => manager.startProgressiveDownload(
      mediaId: movie.id,
      title: movie.title,
      contentType: 'movie',
      resolution: resolution,
      mediaType: MediaType.movie,
      posterUrl: movie.artwork.posterUrl,
      overview: movie.overview,
      runtime: movie.runtime,
      genres: movie.genres,
      rating: movie.rating,
      backdropUrl: movie.artwork.backdropUrl,
      year: movie.year,
      contentRating: movie.contentRating,
      getDownloadUrl: jobs.getDownloadUrl,
      prepareDownload: jobs.prepareDownload,
      getJobStatus: jobs.getJobStatus,
      cancelJob: jobs.cancelJob,
    ),
  );
}

/// Progressive-download flow for an episode picked on a show screen, or from
/// the episodes rail download button. Driven by whichever episode is given.
Future<void> startMydiaEpisodeDownload(
  BuildContext context,
  WidgetRef ref, {
  required Episode episode,
  required String? showId,
  required String showTitle,
  String? showPosterUrl,
}) {
  return _runProgressiveDownload(
    context,
    ref,
    contentType: 'episode',
    mediaId: episode.id,
    dialogTitle: '$showTitle - ${episode.episodeCode}',
    hasFiles: episode.files.isNotEmpty,
    start: (manager, resolution, jobs) => manager.startProgressiveDownload(
      mediaId: episode.id,
      title: '$showTitle - ${episode.episodeCode}: ${episode.title}',
      contentType: 'episode',
      resolution: resolution,
      mediaType: MediaType.episode,
      posterUrl: episode.thumbnailUrl,
      overview: episode.overview,
      runtime: episode.runtime,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      showId: showId,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
      thumbnailUrl: episode.thumbnailUrl,
      airDate: episode.airDate,
      getDownloadUrl: jobs.getDownloadUrl,
      prepareDownload: jobs.prepareDownload,
      getJobStatus: jobs.getJobStatus,
      cancelJob: jobs.cancelJob,
    ),
  );
}

/// Progressive-download flow for the episode detail screen's Download button.
/// The caller decides whether the button is enabled (the episode has files).
Future<void> startMydiaEpisodeDetailDownload(
  BuildContext context,
  WidgetRef ref,
  EpisodeDetail episode,
) {
  return _runProgressiveDownload(
    context,
    ref,
    contentType: 'episode',
    mediaId: episode.id,
    dialogTitle: episode.fullTitle,
    start: (manager, resolution, jobs) => manager.startProgressiveDownload(
      mediaId: episode.id,
      title: episode.fullTitle,
      contentType: 'episode',
      resolution: resolution,
      mediaType: MediaType.episode,
      posterUrl: episode.thumbnailUrl ?? episode.show.artwork.posterUrl,
      overview: episode.overview,
      runtime: episode.runtime,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      showId: episode.show.id,
      showTitle: episode.show.title,
      showPosterUrl: episode.show.artwork.posterUrl,
      thumbnailUrl: episode.thumbnailUrl,
      airDate: episode.airDate,
      getDownloadUrl: jobs.getDownloadUrl,
      prepareDownload: jobs.prepareDownload,
      getJobStatus: jobs.getJobStatus,
      cancelJob: jobs.cancelJob,
    ),
  );
}
