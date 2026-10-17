import 'package:flutter/material.dart';

import '../../../core/theme/palette.dart';

/// The bottom dock's frosted-glass recipe. The cast bar floats directly
/// above the dock and must read as the same material, so both use these.
abstract final class DockGlass {
  static const double sideMargin = 12;

  /// Fill alpha. The colour is the ambient tint's surface, applied by
  /// `GlassSurface.chrome`.
  static const double fillOpacity = 0.7;

  static Border border(MydiaPalette palette) =>
      Border.all(color: palette.border.withValues(alpha: 0.2));

  static List<BoxShadow> get shadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.1),
          blurRadius: 16,
          spreadRadius: 2,
          offset: const Offset(0, 4),
        ),
      ];
}
