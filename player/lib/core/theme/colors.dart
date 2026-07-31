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

  // Primary - Blue (main actions, selected items, links)
  static const Color primary = Color(0xFF4B8DF7);
  static const Color primaryFocus = Color(0xFF3B7BF0);

  // Secondary - Violet (premium features, secondary actions)
  static const Color secondary = Color(0xFF9168F8);
  static const Color secondaryFocus = Color(0xFF8050EF);

  // Accent - Cyan (quality badges, highlights)
  static const Color accent = Color(0xFF0EC5E0);
  static const Color accentFocus = Color(0xFF06A8C4);

  // Neutral - Gray (subtle elements)
  static const Color neutral = Color(0xFF141416);
  static const Color neutralFocus = Color(0xFF0E0E10);

  // Semantic colors
  static const Color error = Color(0xFFF04D4D);
  static const Color warning = Color(0xFFF5A623);
  static const Color info = Color(0xFF4B8DF7);
  static const Color success = Color(0xFF12C68B);

  // Text colors - Refined hierarchy
  static const Color textPrimary = Color(0xFFE8EDF4); // ~15:1 contrast
  static const Color textSecondary = Color(0xFF8899AE); // ~7:1 contrast
  static const Color textDisabled = Color(0xFF546580); // ~4.5:1 contrast

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
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color onSecondary = Color(0xFFFFFFFF);
  static const Color onAccent = Color(0xFFFFFFFF);
  static const Color onError = Color(0xFFFFFFFF);
  static const Color onWarning = Color(0xFF1A1200);
  static const Color onSuccess = Color(0xFFFFFFFF);
}
