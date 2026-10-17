import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import 'palette.dart';

/// The theme a viewer picks on this device. All presets are dark.
enum ThemePreset {
  projectionBooth('Projection Booth'),
  oledBlack('OLED Black'),
  slate('Slate'),
  macos('macOS');

  const ThemePreset(this.label);

  final String label;

  /// `macos` needs the native runner's accent, so it is native macOS only.
  /// The web build on a Mac reports [TargetPlatform.macOS] too, hence [isWeb].
  bool isAvailableOn(TargetPlatform platform, {bool isWeb = kIsWeb}) =>
      this != macos || (!isWeb && platform == TargetPlatform.macOS);

  static List<ThemePreset> availableOn(
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
  }) =>
      [
        for (final p in values)
          if (p.isAvailableOn(platform, isWeb: isWeb)) p,
      ];

  static ThemePreset defaultFor(TargetPlatform platform,
          {bool isWeb = kIsWeb}) =>
      macos.isAvailableOn(platform, isWeb: isWeb) ? macos : projectionBooth;

  /// The stored [ThemePreset.name], or the platform default when it is unset,
  /// unknown, or not offered here.
  static ThemePreset resolve(
    String? stored,
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
  }) {
    for (final p in values) {
      if (p.name == stored && p.isAvailableOn(platform, isWeb: isWeb)) return p;
    }
    if (stored != null) debugPrint('[ThemePreset] ignoring stored "$stored"');
    return defaultFor(platform, isWeb: isWeb);
  }

  MydiaPalette palette({Color systemAccent = Palettes.macosDefaultAccent}) =>
      switch (this) {
        projectionBooth => Palettes.projectionBooth,
        oledBlack => Palettes.oledBlack,
        slate => Palettes.slate,
        macos => Palettes.macos(systemAccent),
      };
}
