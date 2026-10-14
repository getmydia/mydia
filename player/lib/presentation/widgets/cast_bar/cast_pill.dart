import 'package:flutter/material.dart';

import '../glass_surface.dart';
import '../native_glass.dart';
import '../nav/dock_glass.dart';

/// The glass pill every cast bar state renders in, matching the dock it
/// floats above. Radius 18 rather than the dock's 22 because it is shorter.
class CastPill extends StatelessWidget {
  const CastPill({super.key, required this.child});

  /// NativeGlass's cornerRadius in [build] must match.
  static const radius = BorderRadius.all(Radius.circular(18));

  /// Widest the bar grows beside the desktop sidebar, including this pill's
  /// own side margins. Wider than this the scrubber gains nothing and the
  /// bar only covers more content.
  static const double maxWidth = 720;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DockGlass.sideMargin),
      child: DecoratedBox(
        decoration:
            BoxDecoration(borderRadius: radius, boxShadow: DockGlass.shadow),
        // Same tint as the dock (NativeGlass.defaultTint), so the bar and
        // the dock it floats above read as one material.
        child: NativeGlass(
          cornerRadius: 18,
          fallback: (child) => GlassSurface(
            blurSigma: DockGlass.blurSigma,
            fillColor: DockGlass.fill,
            borderRadius: radius,
            border: DockGlass.border,
            child: child,
          ),
          // Transparent Material so IconButton ink and tooltips still work
          // on glass.
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: const EdgeInsets.all(8), child: child),
          ),
        ),
      ),
    );
  }
}
