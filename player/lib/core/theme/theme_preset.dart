import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;

import 'linux_desktop.dart';
import 'palette.dart';

/// The theme a viewer picks on this device. All presets are dark.
enum ThemePreset {
  projectionBooth,
  oledBlack,
  slate,
  macos,
  linux;

  /// `macos` needs the native runner's accent, so it is native macOS only;
  /// `linux` reads the desktop through D-Bus, so it is native Linux only.
  /// The web build reports the host's [TargetPlatform] too, hence [isWeb].
  bool isAvailableOn(TargetPlatform platform, {bool isWeb = kIsWeb}) =>
      switch (this) {
        macos => !isWeb && platform == TargetPlatform.macOS,
        linux => !isWeb && platform == TargetPlatform.linux,
        _ => true,
      };

  static List<ThemePreset> availableOn(
    TargetPlatform platform, {
    bool isWeb = kIsWeb,
  }) =>
      [
        for (final p in values)
          if (p.isAvailableOn(platform, isWeb: isWeb)) p,
      ];

  /// The native preset where there is one, else Projection Booth.
  static ThemePreset defaultFor(TargetPlatform platform,
      {bool isWeb = kIsWeb}) {
    for (final native in const [macos, linux]) {
      if (native.isAvailableOn(platform, isWeb: isWeb)) return native;
    }
    return projectionBooth;
  }

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

  MydiaPalette palette({
    Color systemAccent = Palettes.macosDefaultAccent,
    LinuxDesktop linuxDesktop = LinuxDesktop.other,
    Color? linuxAccent,
  }) =>
      switch (this) {
        projectionBooth => Palettes.projectionBooth,
        oledBlack => Palettes.oledBlack,
        slate => Palettes.slate,
        macos => Palettes.macos(systemAccent),
        linux => Palettes.linux(linuxDesktop, linuxAccent),
      };
}
