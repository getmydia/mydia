import 'package:flutter/material.dart';

/// Colours that do not change with the theme preset: semantic states, OSD
/// text tones and overlays. Everything a preset changes (grounds, surfaces,
/// accent, text, borders) is in `MydiaPalette` (palette.dart), read with
/// `context.palette`.
class AppColors {
  // Semantic colors
  static const Color error = Color(0xFFF04D4D);
  // Warning sits at hue 22 against the accent's 35 and error's 0. The spacing
  // is tight, so warning is never signalled by colour alone: every warning
  // surface carries an icon and a label.
  static const Color warning = Color(0xFFE8722C);
  static const Color info = Color(0xFF5B9BFF);
  static const Color success = Color(0xFF12C68B);

  // Semantic tones for text on the OSD material. `warning` measures ~4.3:1
  // there, under the 4.5:1 text floor; these clear it
  // (osd_legibility_test.dart). They began as the stats-for-nerds panel's
  // private good/warn tones.
  static const Color successText = Color(0xFF4FD8A8);
  static const Color warningText = Color(0xFFE8B27C);

  // Overlay colors (for hover states)
  static const Color overlayDark = Color(0xCC000000); // 80% opacity black
  static const Color overlayLight = Color(0x33000000); // 20% opacity black

  // Content colors (text on colored backgrounds)
  static const Color onError = Color(0xFFFFFFFF);
  static const Color onWarning = Color(0xFF1A1200);
  static const Color onSuccess = Color(0xFFFFFFFF);
}
