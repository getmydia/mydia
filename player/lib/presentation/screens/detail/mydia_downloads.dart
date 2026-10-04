/// Progressive-download flows for Mydia items: quality dialog, then
/// `startProgressiveDownload` through the unified download job service. Shared
/// by the movie, show and episode screens.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_job_providers.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/models/episode_detail.dart';
import '../../../domain/models/movie_detail.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// Starts a progressive download of a Mydia movie.
Future<void> startMydiaMovieDownload(
  BuildContext context,
  WidgetRef ref,
  MovieDetail movie,
) async {
  final isDownloadedAsync = ref.read(isMediaDownloadedProvider(movie.id));
  final isDownloaded = isDownloadedAsync.value ?? false;
  final hasFiles = movie.files.isNotEmpty;
  if (!hasFiles) return;

  if (isDownloaded) {
    if (context.mounted) {
      showToast(context, 'Already downloaded');
    }
  } else {
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: 'movie',
      contentId: movie.id,
      title: movie.title,
    );

    if (selectedResolution != null && context.mounted) {
      final downloadService = ref.read(unifiedDownloadJobServiceProvider);
      final downloadManager = await ref.read(downloadManagerProvider.future);

      if (downloadService != null) {
        try {
          await downloadManager.startProgressiveDownload(
            mediaId: movie.id,
            title: movie.title,
            contentType: 'movie',
            resolution: selectedResolution,
            mediaType: MediaType.movie,
            posterUrl: movie.artwork.posterUrl,
            overview: movie.overview,
            runtime: movie.runtime,
            genres: movie.genres,
            rating: movie.rating,
            backdropUrl: movie.artwork.backdropUrl,
            year: movie.year,
            contentRating: movie.contentRating,
            getDownloadUrl: (jobId) async {
              return await downloadService.getDownloadUrl(jobId);
            },
            prepareDownload: () async {
              final status = await downloadService.prepareDownload(
                contentType: 'movie',
                id: movie.id,
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

          if (context.mounted) {
            showToast(
              context,
              'Download started',
              kind: ToastKind.success,
            );
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
    }
  }
}

/// Progressive-download flow for an episode picked on a show screen: the same
/// quality-dialog then `startProgressiveDownload` sequence as
/// `EpisodeDownloadButton._handleDownload`, driven by whichever episode is
/// currently selected.
Future<void> startMydiaEpisodeDownload(
  BuildContext context,
  WidgetRef ref, {
  required Episode episode,
  required String showId,
  required String showTitle,
  String? showPosterUrl,
}) async {
  final isDownloadedAsync = ref.read(isMediaDownloadedProvider(episode.id));
  final isDownloaded = isDownloadedAsync.value ?? false;

  if (isDownloaded) {
    if (context.mounted) {
      showToast(context, 'Already downloaded');
    }
  } else if (episode.files.isNotEmpty) {
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: 'episode',
      contentId: episode.id,
      title: '$showTitle - ${episode.episodeCode}',
    );

    if (selectedResolution != null && context.mounted) {
      final downloadService = ref.read(unifiedDownloadJobServiceProvider);
      final downloadManager = await ref.read(downloadManagerProvider.future);

      if (downloadService != null) {
        try {
          await downloadManager.startProgressiveDownload(
            mediaId: episode.id,
            title: '$showTitle - ${episode.episodeCode}: ${episode.title}',
            contentType: 'episode',
            resolution: selectedResolution,
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
            getDownloadUrl: (jobId) async {
              return await downloadService.getDownloadUrl(jobId);
            },
            prepareDownload: () async {
              final status = await downloadService.prepareDownload(
                contentType: 'episode',
                id: episode.id,
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

          if (context.mounted) {
            showToast(
              context,
              'Download started',
              kind: ToastKind.success,
            );
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
    }
  }
}

/// Progressive-download flow for the episode detail screen's Download button.
/// The caller decides whether the button is enabled (the episode has files).
Future<void> startMydiaEpisodeDetailDownload(
  BuildContext context,
  WidgetRef ref,
  EpisodeDetail episode,
) async {
  final isDownloadedAsync = ref.read(isMediaDownloadedProvider(episode.id));
  final isDownloaded = isDownloadedAsync.value ?? false;

  if (isDownloaded) {
    if (context.mounted) {
      showToast(context, 'Already downloaded');
    }
  } else {
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: 'episode',
      contentId: episode.id,
      title: episode.fullTitle,
    );

    if (selectedResolution != null && context.mounted) {
      final downloadService = ref.read(unifiedDownloadJobServiceProvider);
      final downloadManager = await ref.read(downloadManagerProvider.future);

      if (downloadService != null) {
        try {
          await downloadManager.startProgressiveDownload(
            mediaId: episode.id,
            title: episode.fullTitle,
            contentType: 'episode',
            resolution: selectedResolution,
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
            getDownloadUrl: (jobId) async {
              return await downloadService.getDownloadUrl(jobId);
            },
            prepareDownload: () async {
              final status = await downloadService.prepareDownload(
                contentType: 'episode',
                id: episode.id,
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

          if (context.mounted) {
            showToast(
              context,
              'Download started',
              kind: ToastKind.success,
            );
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
    }
  }
}
