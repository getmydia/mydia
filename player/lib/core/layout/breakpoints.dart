import 'package:flutter/widgets.dart';

/// Responsive breakpoint utilities for adaptive layouts.
///
/// Breakpoints are inspired by common device sizes:
/// - Mobile: < 600px (phones)
/// - Tablet: 600-899px (tablets in portrait, small laptops)
/// - Desktop: 900-1199px (laptops, tablets in landscape)
/// - Widescreen: >= 1200px (desktops, large monitors)
abstract class Breakpoints {
  /// Maximum width for mobile layouts
  static const double mobile = 600;

  /// Minimum width for tablet layouts (when sidebar appears)
  static const double tablet = 900;

  /// Minimum width for desktop layouts
  static const double desktop = 1200;

  /// Minimum width for widescreen layouts
  static const double widescreen = 1600;

  /// Width of the sidebar on desktop
  static const double sidebarWidth = 260;

  /// Check if current screen is mobile size
  static bool isMobile(BuildContext context) =>
      MediaQuery.sizeOf(context).width < mobile;

  /// Check if current screen is tablet size (includes some small laptops)
  static bool isTablet(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= mobile && width < tablet;
  }

  /// Check if current screen is desktop or larger (shows sidebar)
  static bool isDesktop(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= tablet;

  /// Check if current screen is widescreen
  static bool isWidescreen(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= widescreen;

  /// Get responsive card dimensions based on screen width
  static CardSize getCardSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktop) {
      return const CardSize(width: 160, height: 240);
    } else if (width >= tablet) {
      return const CardSize(width: 145, height: 218);
    } else {
      return const CardSize(width: 130, height: 195);
    }
  }

  /// Get responsive content rail height based on screen width
  static double getRailHeight(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktop) {
      return 340;
    } else if (width >= tablet) {
      return 300;
    } else {
      return 260;
    }
  }

  /// Get responsive landscape (16:9) episode-card dimensions based on screen
  /// width. Mirrors [getCardSize] but for the horizontal episodes rail, where
  /// cards are wide stills rather than portrait posters. Widths grow across the
  /// mobile → tablet → desktop tiers; each tier keeps a ~16:9 aspect ratio.
  static CardSize getEpisodeCardSize(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktop) {
      return const CardSize(width: 300, height: 169);
    } else if (width >= tablet) {
      return const CardSize(width: 240, height: 135);
    } else {
      return const CardSize(width: 200, height: 113);
    }
  }

  /// Get responsive episode rail height based on screen width. Sized to the
  /// landscape card height ([getEpisodeCardSize]) plus a fixed strip for the
  /// episode code and title beneath the thumbnail, so it always exceeds the
  /// card height at each tier.
  static double getEpisodeRailHeight(BuildContext context) {
    // Allowance for the code + title strip rendered below each card thumbnail.
    const double labelStrip = 64;
    return getEpisodeCardSize(context).height + labelStrip;
  }

  /// Rail height for the downloads screen's episode cards.
  ///
  /// Downloads cards carry a third label line (file size) beneath the episode
  /// code and title, so they need a taller strip than
  /// [getEpisodeRailHeight]'s two-line allowance.
  static double getDownloadedEpisodeRailHeight(BuildContext context) {
    // Allowance for the code + title + size strip rendered below each card.
    const double labelStrip = 84;
    return getEpisodeCardSize(context).height + labelStrip;
  }

  /// Get responsive horizontal padding based on screen width
  static double getHorizontalPadding(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktop) {
      return 32;
    } else if (width >= tablet) {
      return 24;
    } else {
      return 20;
    }
  }

  /// Get responsive card spacing based on screen width
  static double getCardSpacing(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= desktop) {
      return 24;
    } else if (width >= tablet) {
      return 20;
    } else {
      return 16;
    }
  }
}

/// Represents card dimensions
class CardSize {
  final double width;
  final double height;

  const CardSize({required this.width, required this.height});

  double get aspectRatio => width / height;
}
