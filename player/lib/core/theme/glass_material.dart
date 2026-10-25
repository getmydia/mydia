import 'package:flutter/foundation.dart';

import '../player/input_capabilities.dart';

/// How controls and panels are drawn on this device. Independent of the
/// colour `ThemePreset`: any preset takes either material.
///
/// [liquid] is the Liquid Glass design language (capsule buttons, glass
/// dialogs, sheets and controls) and, where the shader loads, the Liquid
/// Glass material itself. [frosted] is the Material look with frosted
/// panels. Native chrome drawn by the Runners is not affected.
enum GlassMaterial {
  liquid,
  frosted;

  /// Liquid Glass is never offered on TV: the D-pad focus styling and the
  /// 10-foot layout were not designed against glass controls. [isTv] null
  /// means [InputCapabilities.directionalPrimary].
  bool isAvailableOn(
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
    bool? isTv,
  }) =>
      this != liquid || !(isTv ?? InputCapabilities.directionalPrimary);

  static List<GlassMaterial> availableOn(
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
    bool? isTv,
  }) =>
      [
        for (final m in values)
          if (m.isAvailableOn(platform, isWeb: isWeb, isTv: isTv)) m,
      ];

  /// Liquid Glass on native iOS and macOS, Frosted everywhere else. The web
  /// build on a Mac reports [TargetPlatform.macOS] too, hence [isWeb].
  static GlassMaterial defaultFor(
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
    bool? isTv,
  }) {
    final apple = !isWeb &&
        (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS);
    return apple && liquid.isAvailableOn(platform, isWeb: isWeb, isTv: isTv)
        ? liquid
        : frosted;
  }

  /// The stored [GlassMaterial.name], or the platform default when it is
  /// unset, unknown, or not offered here.
  static GlassMaterial resolve(
    String? stored,
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
    bool? isTv,
  }) {
    for (final m in values) {
      if (m.name == stored &&
          m.isAvailableOn(platform, isWeb: isWeb, isTv: isTv)) {
        return m;
      }
    }
    if (stored != null) debugPrint('[GlassMaterial] ignoring stored "$stored"');
    return defaultFor(platform, isWeb: isWeb, isTv: isTv);
  }
}
