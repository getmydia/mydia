/// The sharp backdrop behind the Home hero.
library;

import 'package:flutter/material.dart';

import '../../../core/cache/artwork_decode.dart';
import '../../../core/cache/poster_cache_manager.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/ui/reduced_motion.dart';
import '../../widgets/artwork_image.dart';

/// Every number the hero backdrop is built from.
///
/// Read by `HomeHeroBackdrop` and by `home_hero_backdrop_contrast_test.dart`,
/// which composites the scrim over worst-case white artwork, so a stop cannot
/// drift without the test noticing.
///
/// The art is never covered with a colour. A neutral black scrim sits on it
/// only where text does, and the artwork plus its scrim are then faded out
/// together by an alpha mask, so what is left of the hero is whatever the
/// shell paints behind it.
abstract final class HomeHeroBackdropTokens {
  /// Scrim opacity over the artwork behind the info column, at the column's
  /// right edge, which is where the left-to-right fade is weakest.
  static const double textAlpha = 0.68;

  /// Scrim opacity at the window's left edge, under the rail and the poster.
  static const double edgeAlpha = 0.78;

  /// How far, in logical pixels, the scrim's fade beyond the text column
  /// runs. When the column leaves less room than this the scrim ends at a
  /// proportionally higher opacity instead of at a cliff.
  static const double fadeSpan = 320;

  /// A light dim behind the window controls and title row, as a fraction of
  /// the backdrop height.
  static const double topScrimAlpha = 0.4;
  static const double topScrimEnd = 0.25;

  /// The art is fully opaque down to this fraction of the backdrop's height,
  /// then dissolves to nothing at the bottom edge along a smoothstep curve.
  static const double fadeStart = 0.55;
  static const int _fadeSteps = 10;

  /// The art fades in from nothing across this many pixels at its left edge.
  ///
  /// The hero cannot paint under the floating rail: the shell's navigator
  /// clips its pages at the column, so the art's left edge is the column's,
  /// and a fade keeps it from reading as a hard vertical cut.
  static const double leftRamp = 160;

  /// Gap between the stacked poster and the title block (the hero's own
  /// spacer). The stacked backdrop ends here, fully faded.
  static const narrowPosterGap = 20.0;

  /// The alpha mask: (stops, alphas) for a top-to-bottom gradient.
  static (List<double>, List<double>) get maskCurve {
    final stops = <double>[0.0];
    final alphas = <double>[1.0];
    for (var i = 0; i <= _fadeSteps; i++) {
      final t = i / _fadeSteps;
      final eased = t * t * (3 - 2 * t);
      stops.add(fadeStart + (1 - fadeStart) * t);
      alphas.add(1 - eased);
    }
    return (stops, alphas);
  }

  /// The wide layout's left-to-right black scrim over a backdrop [width]
  /// pixels wide, the hero's own width.
  static LinearGradient leftGradient({
    required double width,
    required double padding,
    required Size posterSize,
    required double gap,
    required double maxTextWidth,
  }) {
    final textRight = textRightEdge(
      width: width,
      padding: padding,
      posterWidth: posterSize.width,
      gap: gap,
      maxTextWidth: maxTextWidth,
    );
    final fraction = (textRight / width).clamp(0.3, 1.0);
    final endAlpha =
        textAlpha * (1 - ((width - textRight) / fadeSpan).clamp(0.0, 1.0));
    final mid = fraction + (1 - fraction) * 0.5;
    // Eased: smoothstep at the halfway point is half the drop.
    final midAlpha = (textAlpha + endAlpha) / 2;
    return LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Colors.black.withValues(alpha: edgeAlpha),
        Colors.black.withValues(alpha: textAlpha),
        Colors.black.withValues(alpha: midAlpha),
        Colors.black.withValues(alpha: endAlpha),
      ],
      stops: [0.0, fraction, mid, 1.0],
    );
  }

  /// The x of the info column's right edge, from the hero's left edge.
  static double textRightEdge({
    required double width,
    required double padding,
    required double posterWidth,
    required double gap,
    required double maxTextWidth,
  }) {
    final available = width - 2 * padding - posterWidth - gap;
    final text = available.clamp(0.0, maxTextWidth);
    return padding + posterWidth + gap + text;
  }
}

/// The artwork, its scrims, and the mask that dissolves them into whatever
/// is behind, sized by the [Positioned] that holds it.
///
/// One image layer, no blur: the ambient backdrop behind the shell already
/// carries the blurred copy. Painted in a `RepaintBoundary` so the hero's
/// controls repainting for focus never repaint the artwork.
class HomeHeroBackdrop extends StatelessWidget {
  const HomeHeroBackdrop({
    super.key,
    required this.request,
    required this.wide,
    required this.padding,
    required this.posterSize,
    required this.gap,
    required this.maxTextWidth,
  });

  final ArtworkRequest request;
  final bool wide;
  final double padding;
  final Size posterSize;
  final double gap;
  final double maxTextWidth;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final (maskStops, maskAlphas) = HomeHeroBackdropTokens.maskCurve;
    return RepaintBoundary(
      child: IgnorePointer(
        child: _leftRamp(
          enabled: wide,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                for (final a in maskAlphas) Colors.white.withValues(alpha: a),
              ],
              stops: maskStops,
            ).createShader(rect),
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
                          width: constraints.maxWidth,
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
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(
                          alpha: HomeHeroBackdropTokens.topScrimAlpha,
                        ),
                        Colors.black.withValues(alpha: 0),
                      ],
                      stops: const [0.0, HomeHeroBackdropTokens.topScrimEnd],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Fades [child] in across [HomeHeroBackdropTokens.leftRamp] pixels at its
  /// left edge.
  static Widget _leftRamp({required bool enabled, required Widget child}) {
    if (!enabled) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final ramp =
            (HomeHeroBackdropTokens.leftRamp / rect.width).clamp(0.0, 1.0);
        return LinearGradient(
          // Smoothstep sampled at quarters, so the ramp has no visible start.
          colors: [
            for (final a in const [0.0, 0.156, 0.5, 0.844, 1.0])
              Colors.white.withValues(alpha: a),
          ],
          stops: [0.0, ramp * 0.25, ramp * 0.5, ramp * 0.75, ramp],
        ).createShader(rect);
      },
      child: child,
    );
  }
}
