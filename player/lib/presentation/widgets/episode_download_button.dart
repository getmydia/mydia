import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/episode.dart';
import '../../domain/models/download.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/downloads/download_providers.dart';
import '../../core/downloads/download_job_providers.dart';
import '../../core/theme/colors.dart';
import 'quality_download_dialog.dart';

/// Standalone progressive-download action for an episode.
///
/// Extracted verbatim from the former `EpisodeCard` so the episodes rail card
/// can embed the proven quality-dialog → `startProgressiveDownload` flow
/// without duplicating it. Renders nothing when the episode has no file or the
/// platform does not support downloads (e.g. Flutter web).
class EpisodeDownloadButton extends ConsumerWidget {
  final Episode episode;
  final String showTitle;
  final String? showId;
  final String? showPosterUrl;

  const EpisodeDownloadButton({
    super.key,
    required this.episode,
    required this.showTitle,
    this.showId,
    this.showPosterUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!episode.hasFile || !isDownloadSupported) {
      return const SizedBox.shrink();
    }

    final isDownloadedAsync = ref.watch(isMediaDownloadedProvider(episode.id));
    final isDownloaded = isDownloadedAsync.value ?? false;

    return _ActionButton(
      icon: isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
      color: isDownloaded ? AppColors.success : AppColors.textSecondary,
      onTap: () => _handleDownload(context, ref, isDownloaded),
      tooltip: isDownloaded ? 'Downloaded' : 'Download',
    );
  }

  Future<void> _handleDownload(
    BuildContext context,
    WidgetRef ref,
    bool isDownloaded,
  ) async {
    if (isDownloaded) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text('Already downloaded'),
              ],
            ),
            backgroundColor: AppColors.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else if (episode.files.isNotEmpty) {
      // Show quality download dialog for progressive downloads
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
            // Start progressive download using the service
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Row(
                    children: [
                      Icon(Icons.download_rounded,
                          color: Colors.white, size: 20),
                      SizedBox(width: 12),
                      Text('Download started'),
                    ],
                  ),
                  backgroundColor: AppColors.primary,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Failed to start download: $e'),
                  backgroundColor: AppColors.error,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }
          }
        }
      }
    }
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _isHovered
                  ? widget.color.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.icon,
              color: widget.color,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}
