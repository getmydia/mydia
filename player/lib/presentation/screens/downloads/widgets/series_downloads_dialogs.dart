import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/downloads/download_providers.dart';
import '../../../../core/theme/colors.dart';
import '../../../../domain/models/download.dart';

/// "Specials" for season 0, "Season N" otherwise. Season 0 is the conventional
/// home for specials in both TVDB and TMDB data.
String seasonLabel(int seasonNumber) =>
    seasonNumber == 0 ? 'Specials' : 'Season $seasonNumber';

/// Confirms stopping an in-progress download.
Future<void> showCancelDownloadDialog(
  BuildContext context,
  WidgetRef ref,
  DownloadTask task,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Cancel Download?'),
      content: Text('Stop downloading ${task.episodeCode}?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Keep',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Cancel Download'),
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
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Delete Episode'),
      content: Text('Delete ${media.episodeCode}?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteDownload(media.mediaId);
}

/// Confirms deleting every downloaded episode in one season.
Future<void> showDeleteSeasonDialog(
  BuildContext context,
  WidgetRef ref, {
  required String showId,
  required String showTitle,
  required int seasonNumber,
  required int episodeCount,
}) async {
  final label = seasonLabel(seasonNumber);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Delete $label?'),
      content: Text(
        'Delete $episodeCount episode${episodeCount == 1 ? '' : 's'} '
        'from $label of "$showTitle"?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteSeasonDownloads(showId, seasonNumber);
}

/// Confirms deleting every download for the show, queued or complete.
///
/// Returns true when the delete ran, so the caller can pop the now-empty
/// screen. Popping is the caller's job because this function does not know
/// whether it was opened from the screen itself.
Future<bool> showDeleteAllDialog(
  BuildContext context,
  WidgetRef ref, {
  required String showId,
  required String showTitle,
  required int totalCount,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Delete All Episodes'),
      content: Text(
        'Delete all $totalCount episode${totalCount == 1 ? '' : 's'} '
        'of "$showTitle"?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(backgroundColor: AppColors.error),
          child: const Text('Delete All'),
        ),
      ],
    ),
  );

  if (confirmed != true) return false;

  final service = await ref.read(downloadManagerProvider.future);
  await service.deleteSeriesDownloads(showId);
  return true;
}
