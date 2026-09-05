import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../domain/models/available_update.dart';
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
}
