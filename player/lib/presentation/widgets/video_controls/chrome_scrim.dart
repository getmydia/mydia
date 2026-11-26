import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/depth_tokens.dart';
import '../glass/osd_glass.dart';

/// The darkening behind the playback bars: one band at the top, one at the
/// bottom, each solid behind its bar and fading to nothing beyond it.
///
/// Replaces a per-pill backdrop blur. The plateau is the OSD fill, so a pill
/// painted on top reads against the same colour wherever the video is bright.
/// Place it in a [Stack] that fills the video; it ignores pointers.
class ChromeScrim extends StatelessWidget {
  /// Creates a scrim whose bands are solid for [topHeight] and
  /// [bottomHeight] logical pixels, then fade over [fadeExtentFor] the
  /// scrim's height.
  const ChromeScrim({
    super.key,
    required this.topHeight,
    required this.bottomHeight,
  });

  /// Height of the solid region at the top, behind the top bar.
  final double topHeight;

  /// Height of the solid region at the bottom, behind the bottom bar.
  final double bottomHeight;

  /// Longest fade beyond each solid region.
  static const double maxFadeExtent = 96;

  /// Share of the scrim's height a fade may take when that is shorter than
  /// [maxFadeExtent].
  static const double fadeHeightFraction = 0.12;

  /// Length of the fade beyond each solid region in a scrim [height] tall:
  /// [maxFadeExtent], or 12 % of [height] when that is shorter. On a short
  /// landscape phone two full 96 px fades would meet in the middle and darken
  /// the whole picture.
  static double fadeExtentFor(double height) =>
      math.min(maxFadeExtent, height * fadeHeightFraction);

  /// Key of the top band.
  static const Key topKey = Key('chrome-scrim-top');

  /// Key of the bottom band.
  static const Key bottomKey = Key('chrome-scrim-bottom');

  static const Color _transparent = Color(0x00000000);

  @override
  Widget build(BuildContext context) {
    final glass = OsdGlass.of(context) != OsdGlassMode.off;
    final plateau = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdFillOpacity,
    );
    return Positioned.fill(
      child: IgnorePointer(
        child: LayoutBuilder(
          builder: (context, constraints) => glass
              ? _glassBands(fadeExtentFor(constraints.maxHeight))
              : _bands(plateau, fadeExtentFor(constraints.maxHeight)),
        ),
      ),
    );
  }

  /// Liquid Glass modes: no plateau, just the edge opacity fading to nothing
  /// over each bar's height plus [fadeExtent].
  Widget _glassBands(double fadeExtent) {
    final edge = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdLiquidScrimOpacity,
    );
    Widget band(Key key, List<Color> colors) => DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: const [0, 1],
        ),
      ),
    );
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topHeight + fadeExtent,
          child: band(topKey, [edge, _transparent]),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: bottomHeight + fadeExtent,
          child: band(bottomKey, [_transparent, edge]),
        ),
      ],
    );
  }

  Widget _bands(Color plateau, double fadeExtent) {
    final topExtent = topHeight + fadeExtent;
    final bottomExtent = bottomHeight + fadeExtent;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topExtent,
          child: DecoratedBox(
            key: topKey,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [plateau, plateau, _transparent],
                stops: [0, topHeight / topExtent, 1],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: bottomExtent,
          child: DecoratedBox(
            key: bottomKey,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_transparent, plateau, plateau],
                stops: [0, fadeExtent / bottomExtent, 1],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
