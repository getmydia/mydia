/// One landscape Continue Watching card: artwork over a title and a progress
/// bar with the time left.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/focus_highlight.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/source_artwork.dart';

class ContinueWatchingCard extends ConsumerWidget {
  const ContinueWatchingCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onContextMenu,
    this.trailingLabel,
  });

  /// Muted text after the episode caption, on the same single line, such as
  /// the server name on All servers. Null on a source's own home.
  final String? trailingLabel;

  static const Size artSize = Size(280, 120);

  /// The card's height: the artwork plus the caption block.
  ///
  /// Room for an episode's caption line and for text scaled up to about 1.3.
  static const double height = 232;

  final ItemSummary item;
  final VoidCallback onTap;

  /// Long-press on touch, secondary tap on desktop.
  final void Function(BuildContext cardContext)? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = watchStatusFor(item.userState, item.durationSeconds);
    final left = _timeLeft(item);
    final art = item.backdrop ?? item.poster;
    final request = art == null
        ? null
        : ref
            .watch(sourceArtworkProvider((
              sourceId: item.ref.sourceId,
              art: art,
              width: SourcePoster.artworkWidth,
            )))
            .value;
    final hoverSource = request == null
        ? null
        : BackdropSource(
            imageUrl: request.url,
            id: request.url,
            headers: request.headers,
            cacheKey: request.cacheKey,
          );
    const radius = BorderRadius.all(Radius.circular(AppTheme.radiusCard));
    final textTheme = Theme.of(context).textTheme;
    final caption = [
      if (item.showTitle != null) item.subtitle,
      trailingLabel,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

    // Hovering the card drives the shell's ambient backdrop to its artwork,
    // the way a poster does.
    return MouseRegion(
      onEnter: (_) {
        if (hoverSource != null) publishBackdropHover(ref, hoverSource);
      },
      onExit: (_) => clearBackdropHover(ref),
      child: FocusHighlight(
        onActivate: onTap,
        borderRadius: radius,
        child: GestureDetector(
          onTap: onTap,
          onLongPress:
              onContextMenu == null ? null : () => onContextMenu!(context),
          onSecondaryTap:
              onContextMenu == null ? null : () => onContextMenu!(context),
          child: SizedBox(
            width: artSize.width,
            child: GlassSurface.faux(
              fillColor: Colors.white.withValues(alpha: 0.07),
              borderRadius: radius,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: artSize.height,
                    child: art == null
                        ? const ColoredBox(color: AppColors.surfaceVariant)
                        : SourceArtworkImage(
                            sourceId: item.ref.sourceId,
                            art: art,
                            fallback: const ColoredBox(
                              color: AppColors.surfaceVariant,
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.showTitle ?? item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.titleSmall,
                        ),
                        // An episode names its place in the series; the
                        // label (a server name) shares that one line, so
                        // the card never grows.
                        if (caption.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  key: const Key('continue-card-progress'),
                                  value: (status?.percentage ?? 0) / 100,
                                  minHeight: 4,
                                  color: AppColors.primary,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.16),
                                ),
                              ),
                            ),
                            if (left != null) ...[
                              const SizedBox(width: 10),
                              Text(left, style: textTheme.bodySmall),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `22m left`, `1h 4m left`, or null without a duration.
String? _timeLeft(ItemSummary item) {
  final duration = item.durationSeconds;
  final progress = item.userState.progressSeconds ?? 0;
  if (duration == null || duration <= 0) return null;
  final minutes = ((duration - progress).clamp(0, duration) / 60).round();
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '${h}h ${m}m left' : '${m}m left';
}
