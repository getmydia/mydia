import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/detail/detail_views.dart';
import '../../domain/sources/item.dart';
import '../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../core/downloads/download_providers.dart';
import '../../core/theme/colors.dart';
import '../screens/detail/download_metadata.dart';
import '../screens/detail/start_download.dart';

/// Standalone progressive-download action for an episode.
///
/// Extracted verbatim from the former `EpisodeCard` so the episodes rail card
/// can embed the proven quality-dialog → `startProgressiveDownload` flow
/// without duplicating it. Renders nothing when the episode has no file or the
/// platform does not support downloads (e.g. Flutter web).
class EpisodeDownloadButton extends ConsumerWidget {
  final EpisodeView episode;

  const EpisodeDownloadButton({super.key, required this.episode});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!episode.hasFile || !isDownloadSupported) {
      return const SizedBox.shrink();
    }

    final item = episode.target.ref;

    final isDownloadedAsync = ref.watch(isItemDownloadedProvider(item));
    final isDownloaded = isDownloadedAsync.value ?? false;

    return _ActionButton(
      icon: isDownloaded ? Icons.download_done_rounded : Icons.download_rounded,
      color: isDownloaded ? AppColors.success : AppColors.textSecondary,
      onTap: () => _handleDownload(context, ref, item),
      tooltip: isDownloaded ? 'Downloaded' : 'Download',
    );
  }

  Future<void> _handleDownload(
      BuildContext context, WidgetRef ref, ItemRef item) {
    return startItemDownload(
      context,
      ref,
      item: item,
      metadata: episodeDownloadMetadata(episode),
    );
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
