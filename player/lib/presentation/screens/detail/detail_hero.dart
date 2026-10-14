import 'package:flutter/material.dart';

import '../../../core/theme/ambient_tint/ambient_tint.dart';
import '../../../core/theme/ambient_tint/ambient_tint_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_art.dart';
import '../../widgets/detail_art_image.dart';
import '../../widgets/shell_rail_inset.dart';
import 'detail_sections.dart' show kDetailHeroBreakpoint;

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
    final tint = AmbientTint.of(context);
    final ground = tint.ground;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (art case final art?)
          DetailArtImage(
            art: art,
            slot: slot,
            placeholder: (_) => Container(color: tint.surface),
            errorWidget: (_) => _empty(tint),
          )
        else
          _empty(tint),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                ground.withValues(alpha: 0.5),
                ground.withValues(alpha: 0.95),
                ground,
              ],
              stops: const [0.0, 0.5, 0.8, 1.0],
            ),
          ),
        ),
        if (overlay != null)
          // The art runs under the rail; the title block stays beside it.
          Positioned(
            left: 20 + ShellRailInset.of(context),
            right: 20,
            bottom: 20,
            child: overlay,
          ),
        if (bottom != null)
          Positioned(left: 0, right: 0, bottom: 0, child: bottom),
      ],
    );
  }

  Widget _empty(AmbientTintColors tint) {
    final icon = fallbackIcon;
    return Container(
      color: tint.surface,
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
    this.poster,
  });

  /// Leads the row on wide layouts only; ignored below
  /// [kDetailHeroBreakpoint].
  final Widget? poster;

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
    final poster = this.poster;
    final showPoster = poster != null &&
        MediaQuery.sizeOf(context).width >= kDetailHeroBreakpoint;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (showPoster) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusHeroPoster),
            child: SizedBox(width: 160, height: 240, child: poster),
          ),
          const SizedBox(width: 24),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: textTheme.displayLarge?.copyWith(
                  fontSize: 40,
                  letterSpacing: -1,
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
