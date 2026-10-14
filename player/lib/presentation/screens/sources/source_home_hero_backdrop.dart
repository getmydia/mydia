/// The sharp backdrop behind the Home hero.
library;

import 'package:flutter/material.dart';

import '../../../core/cache/artwork_decode.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/theme/ambient_tint/ambient_tint.dart';
import '../../../core/ui/reduced_motion.dart';
import '../../widgets/artwork_image.dart';

/// Every number the hero backdrop's legibility gradients are built from.
///
/// Read by `HomeHeroBackdrop` and by `home_hero_backdrop_contrast_test.dart`,
/// which composites them over worst-case white artwork, so a stop cannot
/// drift without the test noticing.
abstract final class HomeHeroBackdropTokens {
  /// Ground opacity over the artwork behind the hero's text column, at the
  /// column's right edge, which is where the left-to-right fade is weakest.
  static const double textAlpha = 0.86;

  /// Ground opacity at the window's left edge, under the rail and the poster.
  static const double edgeAlpha = 0.94;

  /// How far, in logical pixels, the fade beyond the text column runs. When
  /// the column leaves less room than this the fade ends at a proportionally
  /// higher opacity instead of at a cliff.
  static const double fadeSpan = 240;

  /// Wide layout, top to bottom: the dim behind the window controls and title
  /// row, and the fall into the ground. The ground is opaque at the bottom
  /// edge, so the first rail's heading sits on the plain ground.
  static const topStops = [0.0, 0.3];
  static const topAlphas = [0.55, 0.0];
  static const bottomStops = [0.0, 0.45, 0.78, 1.0];
  static const bottomAlphas = [0.0, 0.0, 0.7, 1.0];

  /// Stacked layout. The backdrop ends where the title block begins, fully
  /// opaque there, so the title and the text under it sit on the ground.
  static const narrowTopStops = [0.0, 0.22];
  static const narrowTopAlphas = [0.5, 0.0];
  static const narrowBottomStops = [0.0, 0.45, 1.0];
  static const narrowBottomAlphas = [0.0, 0.0, 1.0];

  /// Gap between the stacked poster and the title block (the hero's own
  /// spacer).
  static const narrowPosterGap = 20.0;

  /// The wide layout's left-to-right fade over a backdrop [width] pixels
  /// wide, which starts [inset] pixels left of the hero's own column.
  ///
  /// Opaque-ish behind the poster and info column, weakest at the info
  /// column's right edge ([textAlpha]), then fading out across the rest of
  /// the art.
  static LinearGradient leftGradient({
    required Color ground,
    required double width,
    required double inset,
    required double padding,
    required Size posterSize,
    required double gap,
    required double maxTextWidth,
  }) {
    final textRight = textRightEdge(
      width: width,
      inset: inset,
      padding: padding,
      posterWidth: posterSize.width,
      gap: gap,
      maxTextWidth: maxTextWidth,
    );
    final fraction = (textRight / width).clamp(0.3, 1.0);
    final endAlpha =
        textAlpha * (1 - ((width - textRight) / fadeSpan).clamp(0.0, 1.0));
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        ground.withValues(alpha: edgeAlpha),
        ground.withValues(alpha: textAlpha),
        ground.withValues(alpha: endAlpha),
      ],
      stops: [0.0, fraction, 1.0],
    );
  }

  /// The x of the info column's right edge, from the backdrop's left edge.
  static double textRightEdge({
    required double width,
    required double inset,
    required double padding,
    required double posterWidth,
    required double gap,
    required double maxTextWidth,
  }) {
    final columnWidth = width - inset;
    final available = columnWidth - 2 * padding - posterWidth - gap;
    final text = available.clamp(0.0, maxTextWidth);
    return inset + padding + posterWidth + gap + text;
  }

  /// A vertical ground gradient from alpha [alphas] at [stops].
  static LinearGradient vertical(
    Color ground,
    List<double> stops,
    List<double> alphas,
  ) =>
      LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [for (final a in alphas) ground.withValues(alpha: a)],
        stops: stops,
      );
}

/// The artwork and the three gradients that keep text legible over it,
/// sized by the [Positioned] that holds it.
///
/// One image layer, no blur: the ambient backdrop behind the shell already
/// carries the blurred copy. Painted in a `RepaintBoundary` so the hero's
/// controls repainting for focus never repaint the artwork.
class HomeHeroBackdrop extends StatelessWidget {
  const HomeHeroBackdrop({
    super.key,
    required this.request,
    required this.wide,
    required this.inset,
    required this.padding,
    required this.posterSize,
    required this.gap,
    required this.maxTextWidth,
  });

  final ArtworkRequest request;
  final bool wide;

  /// How far this layer reaches left of the hero's own column.
  final double inset;
  final double padding;
  final Size posterSize;
  final double gap;
  final double maxTextWidth;

  @override
  Widget build(BuildContext context) {
    final ground = AmbientTint.of(context).ground;
    final reduceMotion = context.reduceMotion;
    return RepaintBoundary(
      child: IgnorePointer(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ArtworkImage(
              imageUrl: request.url,
              headers: request.headers.isEmpty ? null : request.headers,
              cacheKey: request.cacheKey,
              cacheManager: BackdropCacheManager(),
              // The ambient backdrop's decode width, so both read one
              // cache entry.
              decodeWidth: viewportDecodeWidth(
                context,
                sourceWidth: backdropSourceWidth,
              ),
              fit: BoxFit.cover,
              alignment: const Alignment(0, -0.2),
              fadeInDuration: reduceMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 500),
              fadeOutDuration: Duration.zero,
              placeholder: (_) => const SizedBox.expand(),
              errorWidget: (_) => const SizedBox.expand(),
            ),
            if (wide)
              LayoutBuilder(
                builder: (context, constraints) => DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: HomeHeroBackdropTokens.leftGradient(
                      ground: ground,
                      width: constraints.maxWidth,
                      inset: inset,
                      padding: padding,
                      posterSize: posterSize,
                      gap: gap,
                      maxTextWidth: maxTextWidth,
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: HomeHeroBackdropTokens.vertical(
                  ground,
                  wide
                      ? HomeHeroBackdropTokens.bottomStops
                      : HomeHeroBackdropTokens.narrowBottomStops,
                  wide
                      ? HomeHeroBackdropTokens.bottomAlphas
                      : HomeHeroBackdropTokens.narrowBottomAlphas,
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: HomeHeroBackdropTokens.vertical(
                  ground,
                  wide
                      ? HomeHeroBackdropTokens.topStops
                      : HomeHeroBackdropTokens.narrowTopStops,
                  wide
                      ? HomeHeroBackdropTokens.topAlphas
                      : HomeHeroBackdropTokens.narrowTopAlphas,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
