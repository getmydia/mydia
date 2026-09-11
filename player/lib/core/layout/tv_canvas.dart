import 'package:flutter/widgets.dart';

import '../player/input_capabilities.dart';
import 'tv_canvas_scale.dart';

/// Presents a larger logical canvas to [child] on the directional tier.
///
/// Applied as the outermost wrapper of `MaterialApp.router`'s `builder`. It
/// must sit *below* `MaterialApp`, not above it: `WidgetsApp` installs its own
/// `MediaQuery` from the view, which would overwrite an override placed above
/// the app, so a wrapper outside it would have no effect at all.
///
/// A `Transform.scale` with `Alignment.topLeft` plus a container sized to the
/// reciprocal is what makes the tree believe it has a larger canvas. The
/// transform is not a cosmetic zoom on an already-rasterised layer: Flutter
/// rasterises text through the accumulated matrix, so a glyph laid out at 16
/// logical pixels is drawn at 16 * 0.75 * devicePixelRatio device pixels. That
/// is what keeps text crisp at a fractional scale, unlike a CSS `transform:
/// scale()` on a composited bitmap. Confirmed on the target panel in Task 7.
///
/// `padding`, `viewPadding` and `viewInsets` are scaled alongside `size`, or
/// the chrome inset and the navigation-bar inset would each be a third too
/// large for the canvas they are measured against.
class TvCanvas extends StatelessWidget {
  final Widget child;

  const TvCanvas({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scale = TvCanvasScale.computeScale(
      logicalSize: media.size,
      directionalPrimary: InputCapabilities.directionalPrimary,
    );

    if (scale == 1.0) return child;

    return Transform.scale(
      scale: scale,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: media.size.width / scale,
        height: media.size.height / scale,
        child: MediaQuery(
          data: media.copyWith(
            size: media.size / scale,
            padding: media.padding / scale,
            viewPadding: media.viewPadding / scale,
            viewInsets: media.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}
