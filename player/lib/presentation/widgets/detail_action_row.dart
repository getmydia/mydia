import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/colors.dart';

/// Four-button action row under the hero's big Play button: mark
/// watched/unwatched, favorite, download, and (when a trailer exists) open it
/// on YouTube in a new tab. Shared between the movie and TV show hero, since
/// both need the identical row.
class DetailActionRow extends StatelessWidget {
  final bool watched;
  final VoidCallback onToggleWatched;
  final bool isFavorite;
  final VoidCallback onToggleFavorite;
  final VoidCallback onDownload;
  final String? trailerUrl;

  const DetailActionRow({
    super.key,
    required this.watched,
    required this.onToggleWatched,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onDownload,
    required this.trailerUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _ActionButton(
          icon: watched
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          label: 'Watched',
          highlighted: watched,
          highlightColor: AppColors.success,
          onTap: onToggleWatched,
        ),
        _ActionButton(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: 'Favorite',
          highlighted: isFavorite,
          highlightColor: AppColors.error,
          onTap: onToggleFavorite,
        ),
        _ActionButton(
          icon: Icons.download_rounded,
          label: 'Download',
          highlighted: false,
          highlightColor: AppColors.primary,
          onTap: onDownload,
        ),
        if (trailerUrl != null)
          _ActionButton(
            icon: Icons.smart_display_rounded,
            label: 'Trailer',
            highlighted: false,
            highlightColor: AppColors.primary,
            onTap: () => _openTrailer(context, trailerUrl!),
          ),
      ],
    );
  }

  Future<void> _openTrailer(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open trailer'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool highlighted;
  final Color highlightColor;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.highlighted,
    required this.highlightColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlighted ? highlightColor : AppColors.textPrimary;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: highlighted
                    ? highlightColor.withValues(alpha: 0.15)
                    : AppColors.surfaceVariant,
                border: Border.all(
                  color: highlighted
                      ? highlightColor.withValues(alpha: 0.45)
                      : AppColors.border,
                ),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                  fontSize: 10.5, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
