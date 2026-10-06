import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/bulk_download_helper.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/original_download.dart';
import '../../../core/sources/source_season_download.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/download.dart';
import '../../../domain/models/download_request.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/download_metadata.dart';

/// Queues every episode of the selected season. A source that offers more
/// than one quality is asked which, once, for the whole season.
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
      onPressed: () => _download(context, ref, seasonTarget.ref),
    );
  }

  /// The option to queue every episode with: the lone one a source offers
  /// without asking, else the viewer's pick. Null when cancelled. The first
  /// episode with a file stands for the season, as every episode of one
  /// season is offered the same choices.
  Future<String?> _chooseOption(
    BuildContext context,
    MediaSource source,
    ItemRef seasonRef,
  ) async {
    final downloadable = source.as<Downloadable>();
    if (downloadable == null) return originalOptionId;
    final page = await source.children(seasonRef);
    final first =
        page.items.where((e) => e.defaultVersionId != null).firstOrNull;
    if (first == null) return originalOptionId;
    final options = await downloadable.downloadOptions(first.ref);
    if (options.length < 2) {
      return options.firstOrNull?.resolution ?? originalOptionId;
    }
    if (!context.mounted) return null;
    final picked = await pickDownloadOption(
      context,
      title: '${show.title} - Season ${season.number}',
      options: Future.value(options),
    );
    return picked?.resolution;
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    ItemRef seasonRef,
  ) async {
    final showRef = show.target.ref;
    final source = ref.read(mediaSourceProvider(showRef.sourceId));
    final manager = await ref.read(downloadManagerProvider.future);
    if (!context.mounted) return;
    if (source == null) {
      showToast(context, 'This source is not available', kind: ToastKind.error);
      return;
    }
    final BulkDownloadResult result;
    try {
      final optionId = await _chooseOption(context, source, seasonRef);
      if (optionId == null) return;
      result = await queueSourceSeason(
        source: source,
        season: seasonRef,
        optionId: optionId,
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
