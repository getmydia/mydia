import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'platform_features_stub.dart'
    if (dart.library.io) 'platform_features_native.dart' as platform;

/// Rendering tier for the playback chrome's glass material.
///
/// `BackdropFilter` — and especially `ImageFilter.compose` with a colour matrix
/// — is the expensive path on Flutter web. Widgets read [PlatformFeatures
/// .playerGlassTier] rather than branching on `kIsWeb` themselves, so the
/// policy lives in one place and tests can force a tier.
enum PlayerGlassTier {
  /// Blur + saturation boost. Native desktop and mobile.
  full,

  /// Blur only, no colour matrix. Web.
  reduced,

  /// No live blur at all; compensating denser fill. Contingency only — adopt
  /// solely if web verification measures an actual frame-rate problem.
  faux,
}

/// Service to detect platform-specific capabilities and features
class PlatformFeatures {
  /// Check if running on mobile (iOS or Android)
  static bool get isMobile {
    if (kIsWeb) return false;
    return platform.isIOS || platform.isAndroid;
  }

  /// Check if running on desktop (macOS, Windows, or Linux)
  static bool get isDesktop {
    if (kIsWeb) return false;
    return platform.isMacOS || platform.isWindows || platform.isLinux;
  }

  /// Check if running on iOS
  static bool get isIOS {
    if (kIsWeb) return false;
    return platform.isIOS;
  }

  /// Check if running on Android
  static bool get isAndroid {
    if (kIsWeb) return false;
    return platform.isAndroid;
  }

  /// Check if running on macOS
  static bool get isMacOS {
    if (kIsWeb) return false;
    return platform.isMacOS;
  }

  /// Check if running on Windows
  static bool get isWindows {
    if (kIsWeb) return false;
    return platform.isWindows;
  }

  /// Check if running on Linux
  static bool get isLinux {
    if (kIsWeb) return false;
    return platform.isLinux;
  }

  /// Check if running on web
  static bool get isWeb => kIsWeb;

  /// Check if gesture controls should be enabled (mobile only)
  static bool get supportsGestureControls => isMobile;

  /// Check if keyboard shortcuts should be enabled: native desktop or web —
  /// both have a physical keyboard. This was previously `isDesktop` alone,
  /// which left a narrowed desktop *or web* browser window with no in-bar
  /// episode-nav buttons (viewport-width-gated, not platform-gated — see
  /// `PanelMetrics.touchTargets`/`TransportSurface.compact`), no
  /// `UpNextOverlay` (autoplay-only, next-episode-only), and — before this
  /// fix — no keyboard fallback either, since [supportsKeyboardShortcuts]
  /// was false on web. `isDesktop` itself is left alone: its live consumers
  /// are now `../window/window_drag_service_native.dart` (gating OS window dragging)
  /// and `playback_chrome.dart` (gating the window-drag and double-click
  /// fullscreen callbacks) — the double-click-to-fullscreen gating that used
  /// to live in `player_screen.dart` was removed from there by a later
  /// commit on this branch.
  static bool get supportsKeyboardShortcuts =>
      computeSupportsKeyboardShortcuts(isDesktop: isDesktop, isWeb: isWeb);

  /// Pure predicate behind [supportsKeyboardShortcuts], exposed separately so
  /// it can be unit-tested for every platform combination without actually
  /// running on each platform. `kIsWeb` is a compile-time constant baked in
  /// per build target — there is no way for a single `flutter test` run
  /// (always non-web) to observe what this evaluates to *on* web, so the
  /// underlying boolean logic has to be testable independently of the real
  /// [isDesktop]/[isWeb] values.
  @visibleForTesting
  static bool computeSupportsKeyboardShortcuts({
    required bool isDesktop,
    required bool isWeb,
  }) =>
      isDesktop || isWeb;

  /// Check if Picture-in-Picture is supported (mobile only)
  static bool get supportsPiP => isMobile;

  /// Check if background audio is supported (mobile only)
  static bool get supportsBackgroundAudio => isMobile;

  /// Which glass material the playback chrome should render.
  ///
  /// [PlayerGlassTier.faux] is never selected automatically; it is a
  /// contingency to be wired deliberately if web verification shows a real
  /// performance problem.
  static PlayerGlassTier get playerGlassTier =>
      isWeb ? PlayerGlassTier.reduced : PlayerGlassTier.full;

  /// Get a human-readable platform name
  static String get platformName {
    if (kIsWeb) return 'Web';
    return platform.platformName;
  }
}
