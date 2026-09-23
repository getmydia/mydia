import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/theme/colors.dart';

/// The status dot's meaning, not its color.
enum CastDot { live, idle, lost }

/// One pill row: leading tile, title over an optional status line, actions.
class CastBarRow extends StatelessWidget {
  const CastBarRow({
    super.key,
    required this.leading,
    required this.title,
    this.status,
    this.dot,
    this.actions = const [],
  });

  final Widget leading;
  final String title;
  final String? status;
  final CastDot? dot;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = this.status;
    final dot = this.dot;
    return Row(
      children: [
        leading,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      if (dot != null) ...[
                        _StatusDot(dot),
                        const SizedBox(width: 5),
                      ],
                      Flexible(
                        child: Text(
                          status,
                          style: text.bodySmall
                              ?.copyWith(color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          actions[i],
        ],
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot(this.dot);

  final CastDot dot;

  @override
  Widget build(BuildContext context) {
    final color = switch (dot) {
      CastDot.live => AppColors.primary,
      CastDot.idle => AppColors.textDisabled,
      CastDot.lost => AppColors.error,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: dot == CastDot.live
            ? [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)]
            : null,
      ),
    );
  }
}

/// A 34x34 rounded tile for rows with no artwork.
class CastIconTile extends StatelessWidget {
  const CastIconTile({super.key, required this.child, this.accent = false});

  final Widget child;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.textPrimary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: IconTheme(
        data: IconThemeData(
          size: 18,
          color: accent ? AppColors.primary : AppColors.textSecondary,
        ),
        child: child,
      ),
    );
  }
}

/// The poster thumbnail, falling back to an icon tile when there is no
/// artwork or it fails to load.
class CastThumb extends StatelessWidget {
  const CastThumb({
    super.key,
    required this.imageUrl,
    this.fallbackIcon = Icons.cast_connected,
    this.dimmed = false,
  });

  final String? imageUrl;
  final IconData fallbackIcon;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    final fallback = CastIconTile(accent: true, child: Icon(fallbackIcon));
    if (url == null || url.isEmpty) {
      return Opacity(opacity: dimmed ? 0.5 : 1, child: fallback);
    }
    return Opacity(
      opacity: dimmed ? 0.5 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 34,
          height: 50,
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            cacheManager: PosterCacheManager(),
            placeholder: (_, __) => ColoredBox(
                color: AppColors.textPrimary.withValues(alpha: 0.06)),
            errorWidget: (_, __, ___) => fallback,
          ),
        ),
      ),
    );
  }
}

/// Amber tonal pill for a row's main action (View, Reconnect).
class CastPrimaryAction extends StatelessWidget {
  const CastPrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary.withValues(alpha: 0.14),
        foregroundColor: AppColors.primary,
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

/// Quiet text action (Stop on a stale row).
class CastGhostAction extends StatelessWidget {
  const CastGhostAction({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.textSecondary,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(label),
    );
  }
}
