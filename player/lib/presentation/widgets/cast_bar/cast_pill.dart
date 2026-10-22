import 'package:flutter/material.dart';

import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/palette.dart';
import '../glass_surface.dart';
import '../nav/dock_glass.dart';

/// The glass pill every cast bar state renders in, matching the dock it
/// floats above. Radius 18 rather than the dock's 22 because it is shorter.
class CastPill extends StatelessWidget {
  const CastPill({super.key, required this.child});

  static const radius = BorderRadius.all(Radius.circular(18));

  /// Liquid Glass: a capsule. The pill is held at [liquidMinHeight] so its
  /// radius is half its height whatever the state inside it.
  static const double liquidMinHeight = 56;
  static const liquidRadius =
      BorderRadius.all(Radius.circular(liquidMinHeight / 2));

  /// Widest the bar grows beside the desktop sidebar, including this pill's
  /// own side margins. Wider than this the scrubber gains nothing and the
  /// bar only covers more content.
  static const double maxWidth = 720;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final liquid = GlassStyle.of(context);
    final shape = liquid ? liquidRadius : radius;
    final body = Padding(padding: const EdgeInsets.all(8), child: child);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DockGlass.sideMargin),
      child: DecoratedBox(
        decoration:
            BoxDecoration(borderRadius: shape, boxShadow: DockGlass.shadow),
        child: GlassSurface.chrome(
          opacity: DockGlass.fillOpacity,
          borderRadius: shape,
          border: DockGlass.border(context.palette),
          // Transparent Material so IconButton ink and tooltips still work
          // on glass.
          child: Material(
            type: MaterialType.transparency,
            child: liquid
                ? ConstrainedBox(
                    constraints:
                        const BoxConstraints(minHeight: liquidMinHeight),
                    child: body,
                  )
                : body,
          ),
        ),
      ),
    );
  }
}
