import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/bulk_download_helper.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/sources/source_season_download.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_request.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/download_metadata.dart';

/// Queues every episode of the selected season of a non-Mydia show.
class SourceSeasonDownloadButton extends ConsumerWidget {
  final ShowView show;
  final SeasonView season;

  const SourceSeasonDownloadButton({
    super.key,
    required this.show,
    required this.season,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasonTarget = season.target;
    if (seasonTarget == null) return const SizedBox.shrink();
    return IconButton(
      key: const Key('source-season-download'),
      icon: const Icon(
        Icons.download_for_offline_outlined,
        color: AppColors.textSecondary,
        size: 22,
      ),
      tooltip: 'Download season',
      onPressed: () => _download(context, ref, seasonTarget),
    );
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    DetailTarget seasonTarget,
  ) async {
    final showRef = itemRefOf(show.target);
    final source = ref.read(mediaSourceProvider(showRef.sourceId));
    final manager = await ref.read(downloadManagerProvider.future);
    if (!context.mounted) return;
    if (source == null) {
      showToast(context, 'This source is not available', kind: ToastKind.error);
      return;
    }
    final BulkDownloadResult result;
    try {
      result = await queueSourceSeason(
        source: source,
        season: itemRefOf(seasonTarget),
        manager: manager,
        metadataFor: (e) {
          final seasonNumber = e.parentIndex ?? season.number;
          return DownloadMetadata(
            title: '${show.title} - '
                'S${seasonNumber.toString().padLeft(2, '0')}'
                'E${(e.index ?? 0).toString().padLeft(2, '0')}: ${e.title}',
            mediaType: MediaType.episode,
            posterUrl: e.poster?.path,
            thumbnailUrl: e.backdrop?.path,
            backdropUrl: artKey(show.backdrop),
            overview: e.overview,
            runtime:
                e.durationSeconds == null ? null : e.durationSeconds! ~/ 60,
            seasonNumber: seasonNumber,
            episodeNumber: e.index,
            showId: showRef.externalId,
            showTitle: show.title,
            showPosterUrl: artKey(show.poster),
            airDate: e.airDate,
          );
        },
      );
    } catch (e) {
      debugPrint('Failed to list season episodes: $e');
      if (context.mounted) {
        showToast(context, "Could not list this season's episodes",
            kind: ToastKind.error);
      }
      return;
    }
    if (!context.mounted) return;
    showToast(
      context,
      'Queued ${result.queued} episodes'
      '${result.skipped > 0 ? ', ${result.skipped} already downloaded or queued' : ''}'
      '${result.failed > 0 ? ', ${result.failed} failed' : ''}',
      kind: result.failed > 0 && result.queued == 0
          ? ToastKind.error
          : ToastKind.info,
    );
  }
}
