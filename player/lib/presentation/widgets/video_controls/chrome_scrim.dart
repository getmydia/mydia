import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../core/theme/depth_tokens.dart';
import '../glass/osd_glass.dart';

/// The darkening behind the playback bottom bar: solid behind the bar, then
/// an eased fade to nothing above it.
///
/// There is no top band. The top bar's back/title and action pills carry
/// their own OSD fill, so the picture above them stays clear.
///
/// The plateau is the OSD fill, so text and glyphs drawn straight on it read
/// against the same colour wherever the video is bright. In the glass modes
/// it is a pure gradient from `DepthTokens.osdLiquidScrimOpacity` at the
/// screen edge to nothing, with no plateau. Place it in a [Stack] that fills
/// the video; it ignores pointers.
class ChromeScrim extends StatelessWidget {
  /// Creates a scrim that is solid for [bottomHeight] logical pixels, then
  /// fades over [fadeExtentFor] the scrim's height.
  const ChromeScrim({super.key, required this.bottomHeight});

  /// Height of the solid region, behind the bottom bar.
  final double bottomHeight;

  /// Longest fade above the solid region.
  static const double maxFadeExtent = 120;

  /// Share of the scrim's height the fade may take when that is shorter than
  /// [maxFadeExtent].
  static const double fadeHeightFraction = 0.12;

  /// Gradient stops across the fade. A plain two-stop ramp into the plateau
  /// leaves a visible shelf where its slope changes abruptly; sampling an
  /// ease-in-out curve flattens both ends.
  static const int fadeSteps = 12;

  /// Length of the fade above the solid region in a scrim [height] tall:
  /// [maxFadeExtent], or 12 % of [height] when that is shorter, so a short
  /// landscape phone keeps most of its picture.
  static double fadeExtentFor(double height) =>
      math.min(maxFadeExtent, height * fadeHeightFraction);

  /// Key of the band.
  static const Key bottomKey = Key('chrome-scrim-bottom');

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
              ? _glassBand(fadeExtentFor(constraints.maxHeight))
              : _band(plateau, fadeExtentFor(constraints.maxHeight)),
        ),
      ),
    );
  }

  /// Liquid Glass modes: no plateau, just the edge opacity fading to nothing
  /// over the bar's height plus [fadeExtent].
  Widget _glassBand(double fadeExtent) {
    final edge = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdLiquidScrimOpacity,
    );
    return Stack(
      children: [
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: bottomHeight + fadeExtent,
          child: DecoratedBox(
            key: bottomKey,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [const Color(0x00000000), edge],
                stops: const [0, 1],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _band(Color plateau, double fadeExtent) {
    final extent = bottomHeight + fadeExtent;
    final plateauStart = fadeExtent / extent;
    final colors = <Color>[];
    final stops = <double>[];
    for (var i = 0; i <= fadeSteps; i++) {
      final t = i / fadeSteps;
      colors.add(
        plateau.withValues(alpha: plateau.a * Curves.easeInOut.transform(t)),
      );
      stops.add(t * plateauStart);
    }
    colors.add(plateau);
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
