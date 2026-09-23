import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';

/// The bottom dock's frosted-glass recipe. The cast bar floats directly
/// above the dock and must read as the same material, so both use these.
abstract final class DockGlass {
  static const double blurSigma = 10;
  static const double sideMargin = 12;

  static Color get fill => AppColors.surface.withValues(alpha: 0.7);

  static Border get border =>
      Border.all(color: AppColors.border.withValues(alpha: 0.2));

  static List<BoxShadow> get shadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.1),
          blurRadius: 16,
          spreadRadius: 2,
          offset: const Offset(0, 4),
        ),
      ];
}
