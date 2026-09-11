import 'package:flutter/widgets.dart';

import '../player/input_capabilities.dart';
import 'tv_canvas_scale.dart';

/// Presents a larger logical canvas to [child] on the directional tier.
///
/// It is placed in the router's `builder` because that is where the app wraps
/// every routed page, so this `MediaQuery` is read by everything below it in
/// the routed content. The root `MediaQuery` is installed by the `View` widget
/// and `WidgetsApp` never introduces one of its own, so nothing above this
/// point reinstalls or overwrites it.
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

    // OverflowBox, not SizedBox: this widget is the app root, so the view
    // hands it tight constraints equal to the panel's logical size, and a
    // RenderConstrainedBox clamps its child with `enforce`, which would pull
    // the requested 1280x720 back down to 960x540. The canvas would then be
    // laid out at 960x540 while MediaQuery claimed 1280x720, and the transform
    // would paint that unchanged subtree at 0.75 into the corner -- a smaller
    // app with a dead band, the opposite of what this class is for.
    // OverflowBox is the primitive for a child deliberately larger than its
    // parent: it sizes itself to the incoming constraints and hands the child
    // exactly these. `seek_preview.dart` already uses the same idiom.
    return Transform.scale(
      scale: scale,
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: media.size.width / scale,
        maxWidth: media.size.width / scale,
        minHeight: media.size.height / scale,
        maxHeight: media.size.height / scale,
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
