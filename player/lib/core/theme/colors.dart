import 'package:flutter/material.dart';

/// Mydia Design System Colors
///
/// Deep cinematic palette optimized for media browsing.
/// Darker backgrounds let poster art pop, similar to Plex/Netflix.
class AppColors {
  // Base colors - Neutral cinematic ground. No hue of its own, so poster art
  // supplies all the colour on screen (see the Projection Booth palette spec).
  static const Color background = Color(0xFF0B0B0C); // Neutral near-black
  static const Color surface =
      Color(0xFF141416); // Subtle step above background
  static const Color surfaceVariant = Color(0xFF1E1E21); // Elevated surfaces

  // Primary - Warm gold (main actions, selected items, links). The only
  // accent hue in the palette: chrome is neutral so poster art carries the
  // colour, and the accent itself is reserved for actions and state rather
  // than spent on decoration.
  static const Color primary = Color(0xFFE9A23B);
  static const Color primaryFocus = Color(0xFFD08C24);

  // Neutral - Gray (subtle elements)
  static const Color neutral = Color(0xFF141416);
  static const Color neutralFocus = Color(0xFF0E0E10);

  // Semantic colors
  static const Color error = Color(0xFFF04D4D);
  // Warning sits at hue 22 against the accent's 35 and error's 0. The spacing
  // is tight, so warning is never signalled by colour alone: every warning
  // surface carries an icon and a label.
  static const Color warning = Color(0xFFE8722C);
  static const Color info = Color(0xFF5B9BFF);
  static const Color success = Color(0xFF12C68B);

  // Text colors - Refined hierarchy. Ratios are against `background` and are
  // asserted in theme_contrast_test.dart rather than trusted to these comments,
  // which is how textDisabled drifted to 3.19:1 while claiming 4.5:1.
  static const Color textPrimary = Color(0xFFF0EFED); // 17.12:1
  static const Color textSecondary = Color(0xFF9A9894); // 6.83:1
  static const Color textDisabled = Color(0xFF7A7975); // 4.51:1

  // Border colors - More subtle
  static const Color divider = Color(0xFF1D1D21);
  static const Color border = Color(0xFF2E2E33);

  // Overlay colors (for hover states)
  static const Color overlayDark = Color(0xCC000000); // 80% opacity black
  static const Color overlayLight = Color(0x33000000); // 20% opacity black

  // Card hover color
  static const Color cardHover = Color(0xFF26272B);

  // Shimmer colors (for loading states)
  static const Color shimmerBase = Color(0xFF1A1A1D);
  static const Color shimmerHighlight = Color(0xFF26272B);

  // Content colors (text on colored backgrounds)
  static const Color onPrimary = Color(0xFF1A1205);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color onWarning = Color(0xFF1A1200);
  static const Color onSuccess = Color(0xFFFFFFFF);
}
