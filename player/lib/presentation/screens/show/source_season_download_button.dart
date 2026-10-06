import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Queues every episode of the selected season, or of every season from the
/// menu shown when the show has more than one. A source that offers more than
/// one quality is asked which, once, for everything queued.
class SourceSeasonDownloadButton extends ConsumerWidget {
  final ShowView show;
  final SeasonView season;

  /// The seasons with something to download, [season] among them. The menu
  /// with "Download All Seasons" shows when there is more than one.
  final List<SeasonView> seasons;

  const SourceSeasonDownloadButton({
    super.key,
    required this.show,
    required this.season,
    this.seasons = const [],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seasonTarget = season.target;
    if (seasonTarget == null) return const SizedBox.shrink();
    const icon = Icon(
      Icons.download_for_offline_outlined,
      color: AppColors.textSecondary,
      size: 22,
    );
    final all = [
      for (final s in seasons)
        if (s.target != null) s,
    ];
    if (all.length < 2) {
      return IconButton(
        key: const Key('source-season-download'),
        icon: icon,
        tooltip: 'Download season',
        onPressed: () => _download(context, ref, [season]),
      );
    }
    return PopupMenuButton<String>(
      key: const Key('source-season-download'),
      icon: icon,
      tooltip: 'Download season',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (value) =>
          _download(context, ref, value == 'all' ? all : [season]),
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('source-download-one-season'),
          value: 'season',
          child: Row(
            children: [
              const Icon(Icons.folder_rounded, size: 18),
              const SizedBox(width: 12),
              Text('Download Season ${season.number}'),
            ],
          ),
        ),
        const PopupMenuItem(
          key: Key('source-download-all-seasons'),
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

  /// The option to queue every episode with: the lone one a source offers
  /// without asking, else the viewer's pick. Null when cancelled.
  ///
  /// Probing the first downloadable episode of the first season that has one
  /// is a deliberate approximation: every episode of a season (and of a show)
  /// is offered the same options, and asking once beats a request per episode.
  Future<String?> _chooseOption(
    BuildContext context,
    MediaSource source,
    List<SeasonView> targets,
  ) async {
    final downloadable = source.as<Downloadable>();
    if (downloadable == null) return originalOptionId;
    ItemSummary? first;
    for (final s in targets) {
      final page = await source.children(s.target!.ref);
      first = page.items.where((e) => e.defaultVersionId != null).firstOrNull;
      if (first != null) break;
    }
    if (first == null) return originalOptionId;
    final options = await downloadable.downloadOptions(first.ref);
    if (options.length < 2) {
      return options.firstOrNull?.resolution ?? originalOptionId;
    }
    if (!context.mounted) return null;
    final picked = await pickDownloadOption(
      context,
      title: targets.length == 1
          ? '${show.title} - Season ${targets.first.number}'
          : '${show.title} - All Seasons',
      options: Future.value(options),
    );
    return picked?.resolution;
  }

  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    List<SeasonView> targets,
  ) async {
    final showRef = show.target.ref;
    final source = ref.read(mediaSourceProvider(showRef.sourceId));
    final manager = await ref.read(downloadManagerProvider.future);
    if (!context.mounted) return;
    if (source == null) {
      showToast(context, 'This source is not available', kind: ToastKind.error);
      return;
    }
    var queued = 0, skipped = 0, failed = 0;
    try {
      final optionId = await _chooseOption(context, source, targets);
      if (optionId == null) return;
      for (final target in targets) {
        final result = await queueSourceSeason(
          source: source,
          season: target.target!.ref,
          optionId: optionId,
          manager: manager,
          metadataFor: (e) => _metadata(e, target.number, showRef),
        );
        queued += result.queued;
        skipped += result.skipped;
        failed += result.failed;
      }
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
      'Queued $queued episodes'
      '${skipped > 0 ? ', $skipped already downloaded or queued' : ''}'
      '${failed > 0 ? ', $failed failed' : ''}',
      kind: failed > 0 && queued == 0 ? ToastKind.error : ToastKind.info,
    );
  }

  DownloadMetadata _metadata(
      ItemSummary e, int fallbackSeason, ItemRef showRef) {
    final seasonNumber = e.parentIndex ?? fallbackSeason;
    return DownloadMetadata(
      title: '${show.title} - '
          'S${seasonNumber.toString().padLeft(2, '0')}'
          'E${(e.index ?? 0).toString().padLeft(2, '0')}: ${e.title}',
      mediaType: MediaType.episode,
      posterUrl: e.poster?.path,
      thumbnailUrl: e.backdrop?.path,
      backdropUrl: artKey(show.backdrop),
      overview: e.overview,
      runtime: e.durationSeconds == null ? null : e.durationSeconds! ~/ 60,
      seasonNumber: seasonNumber,
      episodeNumber: e.index,
      showId: showRef.externalId,
      showTitle: show.title,
      showPosterUrl: artKey(show.poster),
      airDate: e.airDate,
    );
  }
}
