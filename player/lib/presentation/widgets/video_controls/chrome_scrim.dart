import 'package:material_ui/material_ui.dart';

import '../../../core/theme/depth_tokens.dart';

/// The darkening behind the playback bars: one band at the top, one at the
/// bottom, each solid behind its bar and fading to nothing beyond it.
///
/// Replaces a per-pill backdrop blur. The plateau is the OSD fill, so a pill
/// painted on top reads against the same colour wherever the video is bright.
/// Place it in a [Stack] that fills the video; it ignores pointers.
class ChromeScrim extends StatelessWidget {
  /// Creates a scrim whose bands are solid for [topHeight] and
  /// [bottomHeight] logical pixels, then fade over [fadeExtent].
  const ChromeScrim({
    super.key,
    required this.topHeight,
    required this.bottomHeight,
  });

  /// Height of the solid region at the top, behind the top bar.
  final double topHeight;

  /// Height of the solid region at the bottom, behind the bottom bar.
  final double bottomHeight;

  /// Length of the fade beyond each solid region.
  static const double fadeExtent = 96;

  /// Key of the top band.
  static const Key topKey = Key('chrome-scrim-top');

  /// Key of the bottom band.
  static const Key bottomKey = Key('chrome-scrim-bottom');

  static const Color _transparent = Color(0x00000000);

  @override
  Widget build(BuildContext context) {
    final plateau = DepthTokens.osdTint.withValues(
      alpha: DepthTokens.osdFillOpacity,
    );
    final topExtent = topHeight + fadeExtent;
    final bottomExtent = bottomHeight + fadeExtent;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
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
        ),
      ),
    );
  }
}
