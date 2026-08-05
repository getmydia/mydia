import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../domain/models/search_result.dart';
import '../../../widgets/poster_frame.dart';

/// Poster card for a movie, TV show, or collection search hit.
///
/// Episodes use `EpisodeResultRow` instead, since they have no poster of their
/// own.
///
/// The depth treatment lives in [PosterFrame], so this card matches the library
/// grid exactly. It contributes only the artwork, a type-specific placeholder,
/// the type badge, and the title and caption beneath.
class SearchResultCard extends StatelessWidget {
  final SearchResult result;
  final VoidCallback onTap;

  const SearchResultCard({
    super.key,
    required this.result,
    required this.onTap,
  });

  IconData get _placeholderIcon {
    switch (result.type) {
      case SearchResultType.movie:
        return Icons.movie_rounded;
      case SearchResultType.tvShow:
        return Icons.tv_rounded;
      case SearchResultType.episode:
        return Icons.playlist_play_rounded;
      case SearchResultType.collection:
        return Icons.collections_bookmark_rounded;
    }
  }

  String get _caption {
    final subtitle = result.subtitle;
    if (subtitle != null && subtitle.isNotEmpty) return subtitle;
    return result.yearDisplay;
  }

  static const Widget _loadingPlaceholder = ColoredBox(
    color: AppColors.surfaceVariant,
    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
  );

  Widget _buildPlaceholder() {
    return ColoredBox(
      color: AppColors.surfaceVariant,
      child: Icon(
        _placeholderIcon,
        size: 48,
        color: AppColors.textSecondary,
      ),
    );
  }

  Widget _buildTypeBadge() {
    return Positioned(
      top: 8,
      right: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_placeholderIcon, size: 12, color: Colors.white),
            const SizedBox(width: 4),
            Text(
              result.type.displayName,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = _caption;

    // A click cursor and nothing more: tapping a result opens the title, it
    // does not start playback, so there is no play glyph here. The cursor wraps
    // the whole tap target, which includes the title and caption beneath.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PosterFrame(
                imageUrl: result.posterUrl,
                placeholder: _buildPlaceholder(),
                loadingPlaceholder: _loadingPlaceholder,
                overlays: [_buildTypeBadge()],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              result.title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (caption.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                caption,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
