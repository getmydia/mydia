import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/depth_tokens.dart';

/// The darkening behind the playback bottom bar: solid behind the bar, then
/// an eased fade to nothing above it.
///
/// There is no top band. The top bar's back disc and action capsules carry
/// their own OSD fill, so the picture above them stays clear.
///
/// The plateau is the OSD fill, so text and glyphs drawn straight on it read
/// against the same colour wherever the video is bright. Place it in a
/// [Stack] that fills the video; it ignores pointers.
class ChromeScrim extends StatelessWidget {
  /// Creates a scrim that is solid for [bottomHeight] logical pixels, then
  /// eases to nothing over [extentAbovePlateau].
  const ChromeScrim({
    super.key,
    required this.bottomHeight,
    this.titleHeight = 0,
  });

  /// Height of the solid region: the bar without its title block, plus the
  /// bottom safe inset.
  final double bottomHeight;

  /// Height the title block takes above the solid region (0 when there is no
  /// title). The ease is stretched so the scrim at the block's top edge is
  /// still [DepthTokens.osdTitleScrimOpacity].
  final double titleHeight;

  /// Longest fade above the solid region.
  static const double maxFadeExtent = 160;

  /// Share of the scrim's height the fade may take when that is shorter than
  /// [maxFadeExtent].
  static const double fadeHeightFraction = 0.12;

  /// Gradient stops across the fade. A plain two-stop ramp into the plateau
  /// leaves a visible shelf where its slope changes abruptly; sampling an
  /// ease-in-out curve flattens both ends.
  static const int fadeSteps = 16;

  /// Length of the fade above the solid region in a scrim [height] tall:
  /// [maxFadeExtent], or 12 % of [height] when that is shorter, so a short
  /// landscape phone keeps most of its picture.
  static double fadeExtentFor(double height) =>
      math.min(maxFadeExtent, height * fadeHeightFraction);

  /// The share of the ease already travelled where the scrim has dropped from
  /// the plateau to [DepthTokens.osdTitleScrimOpacity]: the `t` at which
  /// `1 - easeInOut(t)` equals the token over the fill.
  static final double titleEaseFraction = _solveTitleEaseFraction();

  static double _solveTitleEaseFraction() {
    const target =
        DepthTokens.osdTitleScrimOpacity / DepthTokens.osdFillOpacity;
    var low = 0.0;
    var high = 1.0;
    for (var i = 0; i < 40; i++) {
      final mid = (low + high) / 2;
      if (1 - Curves.easeInOut.transform(mid) > target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (low + high) / 2;
  }

  /// Distance from the plateau's top to where the scrim reaches nothing, in a
  /// scrim [height] tall with a [titleHeight] title block above the plateau.
  /// The title block sits inside the fade, so the ease starts after it and is
  /// stretched until the block's top edge is no lighter than
  /// [DepthTokens.osdTitleScrimOpacity].
  static double extentAbovePlateau({
    required double height,
    required double titleHeight,
  }) {
    final fade = fadeExtentFor(height);
    if (titleHeight == 0) return fade;
    return math.max(titleHeight + fade, titleHeight / titleEaseFraction);
  }

  /// Scrim alpha [fromBottom] logical pixels above the bottom edge: the OSD
  /// fill up to [plateau], then one eased fall to nothing.
  static double alphaAt(
    double fromBottom, {
    required double plateau,
    required double titleHeight,
    required double height,
  }) {
    if (fromBottom <= plateau) return DepthTokens.osdFillOpacity;
    final extent = extentAbovePlateau(height: height, titleHeight: titleHeight);
    final t = (fromBottom - plateau) / extent;
    if (t >= 1) return 0;
    return DepthTokens.osdFillOpacity * (1 - Curves.easeInOut.transform(t));
  }

  /// Key of the band.
  static const Key bottomKey = Key('chrome-scrim-bottom');

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => _band(constraints.maxHeight),
        ),
      ),
    );
  }

  Widget _band(double height) {
    final fade = extentAbovePlateau(height: height, titleHeight: titleHeight);
    final extent = bottomHeight + fade;
    final tint = DepthTokens.osdTint;
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= fadeSteps; i++) {
      final t = i / fadeSteps;
      colors.add(
        tint.withValues(
          alpha: alphaAt(
            bottomHeight + fade * (1 - t),
            plateau: bottomHeight,
            titleHeight: titleHeight,
            height: height,
          ),
        ),
      );
      stops.add(t * fade / extent);
    }
    colors.add(tint.withValues(alpha: DepthTokens.osdFillOpacity));
    stops.add(1);
    return Stack(
      children: [
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: extent,
          child: DecoratedBox(
            key: bottomKey,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
                stops: stops,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
