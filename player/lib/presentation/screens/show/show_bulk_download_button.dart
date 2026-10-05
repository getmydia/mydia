import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/downloads/bulk_download_helper.dart';
import '../../../core/downloads/download_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/download_request.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/models/season_info.dart';
import '../../../domain/models/show_detail.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';
import 'season_episodes_controller.dart';

class ShowBulkDownloadButton extends ConsumerWidget {
  final String showId;
  final ShowDetail show;
  final int selectedSeason;
  final List<SeasonInfo> availableSeasons;

  const ShowBulkDownloadButton({
    super.key,
    required this.showId,
    required this.show,
    required this.selectedSeason,
    required this.availableSeasons,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      icon: const Icon(
        Icons.download_rounded,
        color: AppColors.textSecondary,
        size: 22,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      onSelected: (value) {
        if (value == 'season') {
          _handleBulkDownload(
            context,
            ref,
            [selectedSeason],
          );
        } else if (value == 'all') {
          _handleBulkDownload(
            context,
            ref,
            availableSeasons.map((s) => s.seasonNumber).toList(),
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'season',
          child: Row(
            children: [
              const Icon(Icons.folder_rounded, size: 18),
              const SizedBox(width: 12),
              Text('Download Season $selectedSeason'),
            ],
          ),
        ),
        if (availableSeasons.length > 1)
          const PopupMenuItem(
            value: 'all',
            child: Row(
              children: [
                Icon(Icons.folder_copy_rounded, size: 18),
                SizedBox(width: 12),
                Text('Download All Seasons'),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _handleBulkDownload(
    BuildContext context,
    WidgetRef ref,
    List<int> seasonNumbers,
  ) async {
    // Fetch episodes for all requested seasons
    final allEpisodes = <Episode>[];
    for (final seasonNumber in seasonNumbers) {
      try {
        final episodes = await ref.read(
          seasonEpisodesControllerProvider(
            showId: showId,
            seasonNumber: seasonNumber,
          ).future,
        );
        allEpisodes
            .addAll(episodes.where((e) => e.hasFile && e.files.isNotEmpty));
      } catch (e) {
        debugPrint('Failed to fetch episodes for season $seasonNumber: $e');
      }
    }

    if (allEpisodes.isEmpty) {
      if (context.mounted) {
        showToast(context, 'No downloadable episodes found');
      }
      return;
    }

    if (!context.mounted) return;

    // Show quality dialog using the first episode's ID
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: 'episode',
      contentId: allEpisodes.first.id,
      title: seasonNumbers.length == 1
          ? '${show.title} - Season ${seasonNumbers.first}'
          : '${show.title} - All Seasons',
    );

    if (selectedResolution == null || !context.mounted) return;

    final downloadManager = await ref.read(downloadManagerProvider.future);

    // Build sets for skip checks
    final downloadedMediaIds = <String>{};
    final queueMediaIds = <String>{};

    for (final episode in allEpisodes) {
      if (downloadManager.isDownloaded(
        homeMydiaRef(ItemKind.episode, episode.id),
      )) {
        downloadedMediaIds.add(episode.id);
      }
    }

    final queueAsync = ref.read(downloadQueueProvider);
    if (queueAsync.hasValue) {
      for (final task in queueAsync.value!) {
        queueMediaIds.add(task.mediaId);
      }
    }

    // Start bulk downloads
    final result = await startBulkEpisodeDownloads(
      episodes: allEpisodes,
      resolution: selectedResolution,
      showId: showId,
      showTitle: show.title,
      showPosterUrl: show.artwork.posterUrl,
      downloadManager: downloadManager,
      isMediaDownloaded: (id) => downloadedMediaIds.contains(id),
      isMediaInQueue: (id) => queueMediaIds.contains(id),
    );

    if (!context.mounted) return;

    // Show the result
    final message = _buildResultMessage(result);
    showToast(
      context,
      message,
      icon: result.queued > 0 ? Icons.download_rounded : null,
    );
  }

  String _buildResultMessage(BulkDownloadResult result) {
    if (result.queued == 0 && result.skipped > 0) {
      return 'All ${result.skipped} episodes already downloaded or queued';
    }
    final parts = <String>[];
    parts.add(
        'Queued ${result.queued} episode${result.queued != 1 ? 's' : ''} for download');
    if (result.skipped > 0) {
      parts.add('${result.skipped} already downloaded');
    }
    if (result.failed > 0) {
      parts.add('${result.failed} failed');
    }
    return parts.join(', ');
  }
}
