import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/cache/poster_cache_manager.dart';
import '../../../../core/theme/colors.dart';
import '../../../../domain/models/search_result.dart';

/// An episode search hit rendered as a list row.
///
/// Episodes have no poster of their own, so they read as
/// `show name · SxxEyy · episode title` with the episode still as the leading
/// thumbnail, falling back to the parent show's poster when there is no still.
class EpisodeResultRow extends StatelessWidget {
  final SearchResult result;
  final VoidCallback onTap;

  const EpisodeResultRow({
    super.key,
    required this.result,
    required this.onTap,
  });

  String? get _imageUrl => result.thumbnailUrl ?? result.posterUrl;

  String get _context {
    final parts = <String>[
      if (result.subtitle != null && result.subtitle!.isNotEmpty)
        result.subtitle!,
      if (result.episodeCode != null) result.episodeCode!,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = _imageUrl;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 96,
                height: 54,
                child: imageUrl != null
                    ? CachedNetworkImage(
                        imageUrl: imageUrl,
                        fit: BoxFit.cover,
                        cacheManager: PosterCacheManager(),
                        placeholder: (context, url) => const ColoredBox(
                          color: AppColors.surface,
                        ),
                        errorWidget: (context, url, error) => const ColoredBox(
                          color: AppColors.surface,
                          child: Icon(
                            Icons.tv_rounded,
                            size: 20,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      )
                    : const ColoredBox(
                        color: AppColors.surface,
                        child: Icon(
                          Icons.tv_rounded,
                          size: 20,
                          color: AppColors.textSecondary,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_context.isNotEmpty)
                    Text(
                      _context,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 2),
                  Text(
                    result.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
