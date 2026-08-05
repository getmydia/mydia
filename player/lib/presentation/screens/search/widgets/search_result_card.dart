import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/cache/poster_cache_manager.dart';
import '../../../../core/theme/colors.dart';
import '../../../../domain/models/search_result.dart';

/// Poster card for a movie, TV show, or collection search hit.
///
/// Episodes use [EpisodeResultRow] instead, since they have no poster of their
/// own.
class SearchResultCard extends StatefulWidget {
  final SearchResult result;
  final VoidCallback onTap;

  const SearchResultCard({
    super.key,
    required this.result,
    required this.onTap,
  });

  @override
  State<SearchResultCard> createState() => _SearchResultCardState();
}

class _SearchResultCardState extends State<SearchResultCard> {
  bool _isHovered = false;

  IconData get _placeholderIcon {
    switch (widget.result.type) {
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
    final subtitle = widget.result.subtitle;
    if (subtitle != null && subtitle.isNotEmpty) return subtitle;
    return widget.result.yearDisplay;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          transform: Matrix4.diagonal3Values(
            _isHovered ? 1.03 : 1.0,
            _isHovered ? 1.03 : 1.0,
            1.0,
          ),
          transformAlignment: Alignment.center,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      if (_isHovered)
                        BoxShadow(
                          color: AppColors.primary.withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (widget.result.posterUrl != null)
                          CachedNetworkImage(
                            imageUrl: widget.result.posterUrl!,
                            fit: BoxFit.cover,
                            cacheManager: PosterCacheManager(),
                            placeholder: (context, url) => const ColoredBox(
                              color: AppColors.surface,
                              child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                            errorWidget: (context, url, error) => ColoredBox(
                              color: AppColors.surface,
                              child: Icon(
                                _placeholderIcon,
                                size: 48,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          )
                        else
                          ColoredBox(
                            color: AppColors.surface,
                            child: Icon(
                              _placeholderIcon,
                              size: 48,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _placeholderIcon,
                                  size: 12,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  widget.result.type.displayName,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Hover accent only. Tapping a result opens the title,
                        // it does not start playback, so there is no play
                        // glyph here.
                        if (_isHovered)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  AppColors.primary.withValues(alpha: 0.3),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.result.title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (_caption.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  _caption,
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
      ),
    );
  }
}
