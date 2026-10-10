import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_art.dart';
import '../../widgets/detail_art_image.dart';

/// The detail hero's background: artwork, the bottom-darkening gradient, an
/// optional [overlay] inset 20 from the left, right and bottom, and an
/// optional full-width [bottom] strip (the episode's progress line).
class DetailHeroBackground extends StatelessWidget {
  const DetailHeroBackground({
    super.key,
    required this.art,
    required this.slot,
    this.fallbackIcon,
    this.overlay,
    this.bottom,
  });

  final DetailArt? art;
  final ArtSlot slot;

  /// Drawn on the surface colour when there is no art or it fails to load.
  final IconData? fallbackIcon;
  final Widget? overlay;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final overlay = this.overlay;
    final bottom = this.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (art case final art?)
          DetailArtImage(
            art: art,
            slot: slot,
            placeholder: (_) => Container(color: AppColors.surface),
            errorWidget: _empty,
          )
        else
          _empty(context),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                AppColors.background.withValues(alpha: 0.5),
                AppColors.background.withValues(alpha: 0.95),
                AppColors.background,
              ],
              stops: const [0.0, 0.5, 0.8, 1.0],
            ),
          ),
        ),
        if (overlay != null)
          Positioned(left: 20, right: 20, bottom: 20, child: overlay),
        if (bottom != null)
          Positioned(left: 0, right: 0, bottom: 0, child: bottom),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    final icon = fallbackIcon;
    return Container(
      color: AppColors.surface,
      child: icon == null
          ? null
          : Icon(icon, size: 64, color: AppColors.textSecondary),
    );
  }
}

/// The hero's title block: a shadowed headline, an optional secondary line,
/// an optional widget [below] them, and an optional trailing [action] (the
/// play control) aligned to the bottom.
class DetailHeroTitle extends StatelessWidget {
  const DetailHeroTitle({
    super.key,
    required this.title,
    this.subtitle = '',
    this.below,
    this.action,
  });

  final String title;

  /// Hidden when empty.
  final String subtitle;
  final Widget? below;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final below = this.below;
    final action = this.action;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.8),
                      blurRadius: 8,
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: textTheme.bodyMedium
                      ?.copyWith(color: AppColors.textSecondary),
                ),
              ],
              if (below != null) ...[
                const SizedBox(height: 8),
                below,
              ],
            ],
          ),
        ),
        // Gap and control are emitted together so a missing action leaves
        // no dangling spacer.
        if (action != null) ...[
          const SizedBox(width: 16),
          action,
        ],
      ],
    );
  }
}
