/// Download flows for Mydia items: quality dialog, then `start` on the download
/// service. Shared by the movie, show and episode screens and the episode rail
/// download button.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_providers.dart';
import '../../../core/downloads/mydia_download_metadata.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_request.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/models/episode_detail.dart';
import '../../../domain/models/movie_detail.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// The plumbing every Mydia download shares: already-downloaded toast,
/// quality dialog, manager lookup, and the started/failed toasts. [metadata]
/// supplies the per-type fields.
///
/// [hasFiles] is checked after the already-downloaded toast, so an episode
/// without files still reports "Already downloaded" but never opens the dialog.
Future<void> _runDownload(
  BuildContext context,
  WidgetRef ref, {
  required String contentType,
  required String mediaId,
  required String dialogTitle,
  required DownloadMetadata metadata,
  bool hasFiles = true,
}) async {
  final item = homeMydiaRef(
    contentType == 'episode' ? ItemKind.episode : ItemKind.movie,
    mediaId,
  );
  final isDownloaded = ref.read(isItemDownloadedProvider(item)).value ?? false;

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

  final managerFuture = ref.read(downloadManagerProvider.future);

  try {
    final downloadManager = await managerFuture;
    await downloadManager.start(DownloadRequest(
      ref: item,
      optionId: selectedResolution,
      metadata: metadata,
    ));

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

/// Starts a download of a Mydia movie.
Future<void> startMydiaMovieDownload(
  BuildContext context,
  WidgetRef ref,
  MovieDetail movie,
) async {
  if (movie.files.isEmpty) return;

  return _runDownload(
    context,
    ref,
    contentType: 'movie',
    mediaId: movie.id,
    dialogTitle: movie.title,
    metadata: mydiaMovieMetadata(movie),
  );
}

/// Download flow for an episode picked on a show screen, or from the episodes
/// rail download button. Driven by whichever episode is given.
Future<void> startMydiaEpisodeDownload(
  BuildContext context,
  WidgetRef ref, {
  required Episode episode,
  required String? showId,
  required String showTitle,
  String? showPosterUrl,
}) {
  return _runDownload(
    context,
    ref,
    contentType: 'episode',
    mediaId: episode.id,
    dialogTitle: '$showTitle - ${episode.episodeCode}',
    hasFiles: episode.files.isNotEmpty,
    metadata: mydiaEpisodeMetadata(
      episode,
      showId: showId,
      showTitle: showTitle,
      showPosterUrl: showPosterUrl,
    ),
  );
}

/// Download flow for the episode detail screen's Download button.
/// The caller decides whether the button is enabled (the episode has files).
Future<void> startMydiaEpisodeDetailDownload(
  BuildContext context,
  WidgetRef ref,
  EpisodeDetail episode,
) {
  return _runDownload(
    context,
    ref,
    contentType: 'episode',
    mediaId: episode.id,
    dialogTitle: episode.fullTitle,
    metadata: DownloadMetadata(
      title: episode.fullTitle,
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
    ),
  );
}
