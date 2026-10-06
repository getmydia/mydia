import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../domain/sources/collection.dart';
import 'source_artwork.dart';

class CollectionCard extends StatefulWidget {
  final SourceCollection collection;
  final VoidCallback onTap;

  /// Shown under the name, e.g. the server a merged collection came from.
  final String? caption;

  const CollectionCard({
    super.key,
    required this.collection,
    required this.onTap,
    this.caption,
  });

  @override
  State<CollectionCard> createState() => _CollectionCardState();
}

class _CollectionCardState extends State<CollectionCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          transform: _isHovered
              ? (Matrix4.identity()..scaleByDouble(1.02, 1.02, 1.0, 1.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isHovered
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : AppColors.border.withValues(alpha: 0.15),
            ),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.1),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ]
                : [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(15)),
                  child: _buildPosterCollage(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.collection.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (caption != null)
                      Text(
                        caption,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(
                          widget.collection.smart
                              ? Icons.auto_awesome_rounded
                              : Icons.list_rounded,
                          size: 14,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${widget.collection.itemCount} item${widget.collection.itemCount == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPosterCollage() {
    final posters = widget.collection.posters;
    final sourceId = widget.collection.sourceId;

    if (posters.isEmpty) {
      return Container(
        color: AppColors.surfaceVariant,
        child: const Center(
          child: Icon(
            Icons.collections_bookmark_outlined,
            size: 40,
            color: AppColors.textSecondary,
          ),
        ),
      );
    }

    if (posters.length == 1) {
      return SourceArtworkImage(
        sourceId: sourceId,
        art: posters[0],
        fallback: _placeholderTile(),
      );
    }

    return GridView.count(
      crossAxisCount: 2,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 1,
      crossAxisSpacing: 1,
      children: List.generate(4, (index) {
        if (index < posters.length) {
          return SourceArtworkImage(
            sourceId: sourceId,
            art: posters[index],
            fallback: _placeholderTile(),
          );
        }
        return _placeholderTile();
      }),
    );
  }

  Widget _placeholderTile() {
    return Container(
      color: AppColors.surfaceVariant,
      child: const Center(
        child: Icon(
          Icons.movie_outlined,
          size: 24,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
