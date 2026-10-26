import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/downloads/download_providers.dart';
import '../../../../core/sources/source.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/palette.dart';
import '../../../../domain/models/download.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/glass/glass_dialog.dart';

/// "Specials" for season 0, "Season N" otherwise. Season 0 is the conventional
/// home for specials in both TVDB and TMDB data.
String seasonLabel(AppLocalizations l10n, int seasonNumber) => seasonNumber == 0
    ? l10n.downloadsSeasonSpecials
    : l10n.downloadsSeasonNumber(seasonNumber);

/// Confirms stopping an in-progress download.
Future<void> showCancelDownloadDialog(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      backgroundColor: context.palette.surface,
      title: Text(context.l10n.downloadsCancelDownloadTitle),
      content: Text(context.l10n.downloadsCancelEpisodeBody(task.episodeCode)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            context.l10n.downloadsKeep,
            style: TextStyle(color: context.palette.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: Text(context.l10n.downloadsCancelDownloadAction),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final service = await ref.read(downloadManagerProvider.future);
  await service.cancelDownload(task.id);
}

/// Confirms deleting one downloaded episode from disk.
Future<void> showDeleteEpisodeDialog(
  BuildContext context,
  WidgetRef ref,
  DownloadedMedia media,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      backgroundColor: context.palette.surface,
      destructive: true,
      title: Text(context.l10n.downloadsDeleteEpisodeTitle),
      content: Text(context.l10n.downloadsDeleteEpisodeBody(media.episodeCode)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: Text(context.l10n.commonDelete),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteDownload(media.itemRef);
}

/// Confirms deleting every downloaded episode in one season.
Future<void> showDeleteSeasonDialog(
  BuildContext context,
  WidgetRef ref, {
  required SourceId sourceId,
  required String showId,
  required String showTitle,
  required int seasonNumber,
  required int episodeCount,
}) async {
  final label = seasonLabel(context.l10n, seasonNumber);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      backgroundColor: context.palette.surface,
      destructive: true,
      title: Text(context.l10n.downloadsDeleteSeasonTitle(label)),
      content: Text(
        context.l10n.downloadsDeleteSeasonBody(episodeCount, label, showTitle),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            context.l10n.commonCancel,
            style: TextStyle(color: context.palette.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: Text(context.l10n.commonDelete),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteSeasonDownloads(
    sourceId,
    showId,
    seasonNumber,
  );
}

/// Confirms deleting every download for the show, queued or complete.
///
/// Returns true when the delete ran, so the caller can pop the now-empty
/// screen. Popping is the caller's job because this function does not know
/// whether it was opened from the screen itself.
Future<bool> showDeleteAllDialog(
  BuildContext context,
  WidgetRef ref, {
  required SourceId sourceId,
  required String showId,
  required String showTitle,
  required int totalCount,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      backgroundColor: context.palette.surface,
      destructive: true,
      title: Text(context.l10n.downloadsDeleteAllEpisodesTitle),
      content: Text(
        context.l10n.downloadsDeleteAllEpisodesBody(totalCount, showTitle),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            context.l10n.commonCancel,
            style: TextStyle(color: context.palette.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: Text(context.l10n.downloadsDeleteAllAction),
        ),
      ],
    ),
  );

  if (confirmed != true) return false;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteSeriesDownloads(sourceId, showId);
  return true;
}
