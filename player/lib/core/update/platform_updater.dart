import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import '../../domain/models/app_update.dart';
import '../player/platform_features.dart';
import 'updaters/linux_updater.dart';
import 'updaters/macos_updater.dart';
import 'updaters/windows_updater.dart';

/// Abstract interface for platform-specific update application.
abstract class PlatformUpdater {
  /// Whether this platform can replace the running app in-place.
  bool get canUpdateInPlace;

  /// Applies the update. [onProgress] receives values from 0.0 to 1.0.
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  });

  /// Returns the appropriate updater for the current platform, or null
  /// if the platform does not support self-updating (e.g. web, mobile).
  static PlatformUpdater? forCurrentPlatform() {
    if (kIsWeb) return null;
    if (Platform.isWindows) return WindowsUpdater();
    if (Platform.isMacOS) return MacOSUpdater();
    if (Platform.isLinux) return LinuxUpdater();
    return null;
  }

  /// Whether the current platform ships an in-app updater at all.
  ///
  /// Update surfaces gate on this instead of listing platforms themselves, so
  /// a platform without an updater cannot grow a dead update menu item — which
  /// is exactly what iOS had, since the Settings "Updates" section only
  /// excluded web and Android.
  static bool get supportedOnCurrentPlatform => supportedOnPlatform(
        isWeb: PlatformFeatures.isWeb,
        isAndroid: PlatformFeatures.isAndroid,
        isIOS: PlatformFeatures.isIOS,
      );

  /// The support decision itself, separated from the static platform lookups
  /// so it can be exercised for every platform on one machine.
  ///
  /// iOS and Android update through their app stores and web is served by the
  /// Mydia server, so none of them can replace the running app.
  @visibleForTesting
  static bool supportedOnPlatform({
    required bool isWeb,
    required bool isAndroid,
    required bool isIOS,
  }) =>
      !isWeb && !isAndroid && !isIOS;
}
