import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';

/// Below this width the hero body's action column and tag column stack
/// instead of sitting side by side.
const double kDetailHeroBreakpoint = 700;

/// The block under the hero: the action column beside the tag column on wide
/// layouts, stacked above it on narrow ones. [actionColumn] receives
/// `compact: true` on wide layouts.
class DetailHeroBody extends StatelessWidget {
  const DetailHeroBody({
    super.key,
    required this.actionColumn,
    required this.tagColumn,
  });

  final Widget Function(bool compact) actionColumn;
  final Widget tagColumn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= kDetailHeroBreakpoint;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      actionColumn(true),
                      const SizedBox(width: 40),
                      Expanded(child: tagColumn),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      actionColumn(false),
                      const SizedBox(height: 20),
                      tagColumn,
                    ],
                  ),
          );
        },
      ),
    );
  }
}

/// The hero body's right-hand column: an optional [leading] widget (the
/// movie's watched line or progress bar), tag chips, the overview, and the
/// rating line. Each part is omitted when empty.
class DetailTagColumn extends StatelessWidget {
  const DetailTagColumn({
    super.key,
    this.leading,
    required this.tags,
    this.overview,
    this.rating = '',
  });

  final Widget? leading;
  final List<String> tags;
  final String? overview;
  final String rating;

  @override
  Widget build(BuildContext context) {
    final leading = this.leading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (leading != null) ...[
          leading,
          const SizedBox(height: 18),
        ],
        if (tags.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final tag in tags) _TagChip(label: tag)],
          ),
          const SizedBox(height: 18),
        ],
        if (overview case final overview?) ...[
          Text(
            overview,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.6,
                ),
          ),
          const SizedBox(height: 14),
        ],
        if (rating.isNotEmpty) DetailRatingLine(rating: rating),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

/// A star, the rating, and its "TMDB" source label.
class DetailRatingLine extends StatelessWidget {
  const DetailRatingLine({super.key, required this.rating});

  final String rating;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.star_rounded, size: 16, color: AppColors.primary),
        const SizedBox(width: 6),
        Text(
          rating,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        const Text(
          'TMDB',
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// A padded row of [DetailMetadataChip]s; nothing at all when [chips] is
/// empty.
class DetailMetadataWrap extends StatelessWidget {
  const DetailMetadataWrap({super.key, required this.chips});

  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }
}

/// A tinted status chip with an optional leading [icon].
class DetailMetadataChip extends StatelessWidget {
  const DetailMetadataChip({
    super.key,
    required this.label,
    this.icon,
    this.color,
  });

  final String label;
  final IconData? icon;

  /// Defaults to [AppColors.textSecondary].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final chipColor = color ?? AppColors.textSecondary;
    final icon = this.icon;
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: chipColor,
      ),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: chipColor.withValues(alpha: 0.3)),
      ),
      child: icon == null
          ? text
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: chipColor),
                const SizedBox(width: 6),
                text,
              ],
            ),
    );
  }
}

/// An "Overview" heading with an accent bar, and the overview text.
class DetailOverview extends StatelessWidget {
  const DetailOverview({super.key, required this.overview});

  final String overview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Overview',
                style: textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            overview,
            style: textTheme.bodyMedium?.copyWith(
              color: AppColors.textSecondary,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
