/// The featured title at the top of a source's home.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/focus/focus_reveal_section.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/artwork_image.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';

class SourceHomeHero extends ConsumerWidget {
  const SourceHomeHero({super.key, required this.sourceId, required this.item});

  final SourceId sourceId;
  final ItemSummary item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final art = item.backdrop ?? item.poster;
    final request = art == null
        ? null
        : ref
            .watch(sourceArtworkProvider((
              sourceId: sourceId,
              art: art,
              width: SourceBackdrop.artworkWidth,
            )))
            .value;
    // The shell's ambient backdrop follows the hero's artwork.
    // BackdropSource has no header support, so a credentialed URL would fail
    // to load: fall back to the static backdrop for those.
    final ambientUrl = (request?.headers.isEmpty ?? true) ? request?.url : null;
    publishBackdropSource(
      ref,
      ambientUrl == null
          ? BackdropSource.none
          : BackdropSource(imageUrl: ambientUrl, id: item.ref.externalId),
    );

    final size = MediaQuery.of(context).size;
    final isDesktop = Breakpoints.isDesktop(context);
    // On desktop, cap hero height at 450px; on mobile use 50% of screen
    final heroHeight = isDesktop
        ? (size.height * 0.45).clamp(300.0, 450.0)
        : size.height * 0.5;
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    void open() => context.push(sourceItemLocation(item.ref));
    final showTitle = item.showTitle;

    // UP from the first rail lands on the hero's buttons, which sit at its
    // bottom. On a television this reveals the whole hero, not just the button.
    return FocusRevealSection(
      child: GestureDetector(
        onTap: open,
        child: Stack(
          children: [
            ClipRect(
              child: SizedBox(
                width: size.width,
                height: heroHeight,
                child: request != null
                    ? ArtworkImage(
                        imageUrl: request.url,
                        headers: request.headers,
                        cacheKey: request.cacheKey,
                        fit: BoxFit.cover,
                        cacheManager: BackdropCacheManager(),
                        placeholder: (context) =>
                            Container(color: AppColors.surface),
                        errorWidget: (context) => const _HeroFallback(),
                      )
                    : const _HeroFallback(),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.background.withValues(alpha: 0.4),
                      Colors.transparent,
                      AppColors.background.withValues(alpha: 0.9),
                      AppColors.background,
                    ],
                    stops: const [0.0, 0.3, 0.7, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              left: horizontalPadding,
              right: horizontalPadding,
              bottom: isDesktop ? 32 : 24,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'FEATURED',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    item.title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  if (showTitle != null)
                    Text(
                      showTitle,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: AppColors.textSecondary,
                          ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const Key('source-home-hero-play'),
                        onPressed: open,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: open,
                        icon: const Icon(Icons.info_outline_rounded, size: 20),
                        label: const Text('More Info'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          side: BorderSide(
                            color:
                                AppColors.textSecondary.withValues(alpha: 0.5),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
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
    );
  }
}

class _HeroFallback extends StatelessWidget {
  const _HeroFallback();

  @override
  Widget build(BuildContext context) => Container(
        color: AppColors.surface,
        child: const Icon(
          Icons.movie_rounded,
          size: 64,
          color: AppColors.textSecondary,
        ),
      );
}
