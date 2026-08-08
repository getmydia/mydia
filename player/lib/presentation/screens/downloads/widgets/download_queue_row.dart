import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/downloads/download_providers.dart';
import '../../../../core/theme/colors.dart';
import '../../../../domain/models/download.dart';
import 'series_downloads_dialogs.dart';

/// One in-progress download, as three legible lines: title, progress bar, and
/// a single metrics line.
///
/// The previous compact row put every field on one line at 10-11px, which was
/// unreadable. This trades vertical space for legibility, which is the right
/// trade for a section that is usually one or two items long.
class DownloadQueueRow extends ConsumerWidget {
  final DownloadTask task;

  const DownloadQueueRow({super.key, required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = task.isProgressive ? task.combinedProgress : task.progress;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  task.episodeCode,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  task.title,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey('download-queue-row-cancel'),
                onPressed: () => showCancelDownloadDialog(context, ref, task),
                icon: const Icon(Icons.close_rounded),
                color: AppColors.textSecondary,
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Cancel download',
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: const ValueKey('download-queue-row-bar'),
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: AppColors.surfaceVariant,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
          const SizedBox(height: 6),
          _buildMetrics(ref, progress),
        ],
      ),
    );
  }

  /// Scoped to its own [Consumer] so a speed tick rebuilds this line alone and
  /// leaves the title and the progress bar untouched.
  Widget _buildMetrics(WidgetRef ref, double progress) {
    return Consumer(
      builder: (context, ref, _) {
        final speedAsync = ref.watch(downloadSpeedInfoProvider);
        final info = speedAsync.value?[task.id];

        final parts = <String>[
          '${(progress * 100).toStringAsFixed(0)}%',
          task.progressBytesDisplay ?? task.fileSizeDisplay,
        ];
        if (info != null && info.bytesPerSecond > 0) {
          parts.add(info.speedDisplay);
        }

        return Text(
          parts.join('  ·  '),
          key: const ValueKey('download-queue-row-metrics'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
          ),
        );
      },
    );
  }
}
