import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/theme/colors.dart';
import 'progress_overlay.dart';

class MediaPoster extends StatefulWidget {
  final String? posterUrl;
  final String title;
  final double? progressPercentage;
  final bool isFavorite;
  final VoidCallback? onTap;
  final bool showTitle;

  const MediaPoster({
    super.key,
    this.posterUrl,
    required this.title,
    this.progressPercentage,
    this.isFavorite = false,
    this.onTap,
    this.showTitle = true,
  });

  @override
  State<MediaPoster> createState() => _MediaPosterState();
}

class _MediaPosterState extends State<MediaPoster> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: MouseRegion(
              onEnter: (_) => setState(() => _isHovered = true),
              onExit: (_) => setState(() => _isHovered = false),
              child: AnimatedScale(
                scale: _isHovered ? 1.02 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: _isHovered
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        SizedBox.expand(
                          child: widget.posterUrl != null
                              ? CachedNetworkImage(
                                  imageUrl: widget.posterUrl!,
                                  fit: BoxFit.cover,
                                  cacheManager: PosterCacheManager(),
                                  placeholder: (context, url) => Container(
                                    color: AppColors.surfaceVariant,
                                    child: const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                    color: AppColors.surfaceVariant,
                                    child: const Icon(
                                      Icons.movie,
                                      size: 48,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                )
                              : Container(
                                  color: AppColors.surfaceVariant,
                                  child: const Icon(
                                    Icons.movie,
                                    size: 48,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                        ),
                        if (widget.progressPercentage != null &&
                            widget.progressPercentage! > 0)
                          ProgressOverlay(
                              percentage: widget.progressPercentage!),
                        if (widget.isFavorite)
                          const Positioned(
                            top: 8,
                            right: 8,
                            child: Icon(
                              Icons.favorite,
                              color: Colors.red,
                              size: 20,
                            ),
                          ),
                        // Hover overlay with play button
                        AnimatedOpacity(
                          opacity: _isHovered ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          curve: Curves.easeInOut,
                          child: Container(
                            decoration: const BoxDecoration(
                              color: AppColors.overlayDark,
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.play_circle_filled,
                                size: 48,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.showTitle) ...[
            const SizedBox(height: 8),
            Text(
              widget.title,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
