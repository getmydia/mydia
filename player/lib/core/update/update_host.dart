import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../domain/models/available_update.dart';
import 'backends/flatpak_update_backend.dart';
import 'backends/release_update_backend.dart';
import 'backends/sparkle_update_backend.dart';
import 'flatpak_environment.dart';
import 'flatpak_portal.dart';
import 'platform_updater.dart';
import 'update_backend.dart';

/// Everything about the running installation that decides how it updates.
///
/// A value object rather than a pile of static lookups, so every combination
/// can be exercised on one machine.
class UpdateHost {
  final bool isWeb;
  final bool isAndroid;
  final bool isIOS;
  final bool isMacOS;
  final bool isWindows;
  final bool isLinux;
  final bool isFlatpak;
  final String? flatpakBranch;

  const UpdateHost({
    required this.isWeb,
    required this.isAndroid,
    required this.isIOS,
    required this.isMacOS,
    required this.isWindows,
    required this.isLinux,
    this.isFlatpak = false,
    this.flatpakBranch,
  });

  factory UpdateHost.current({
    FlatpakEnvironment flatpak = const FlatpakEnvironment(),
  }) {
    if (kIsWeb) {
      return const UpdateHost(
        isWeb: true,
        isAndroid: false,
        isIOS: false,
        isMacOS: false,
        isWindows: false,
        isLinux: false,
      );
    }

    final linux = Platform.isLinux;
    final inFlatpak = linux && flatpak.isFlatpak;

    return UpdateHost(
      isWeb: false,
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      isMacOS: Platform.isMacOS,
      isWindows: Platform.isWindows,
      isLinux: linux,
      isFlatpak: inFlatpak,
      flatpakBranch: inFlatpak ? flatpak.branch : null,
    );
  }

  /// iOS and Android update through their app stores and web is served by the
  /// Mydia server, so none of them can replace the running app.
  bool get supportsInAppUpdates => !isWeb && !isAndroid && !isIOS;
}

/// The backend for this installation, or null when the platform updates
/// elsewhere.
///
/// Returning null is what keeps a platform without an updater from growing a
/// dead update row, which is the guarantee the old supportedOnCurrentPlatform
/// carried.
UpdateBackend? createUpdateBackend(
  UpdateHost host, {
  required String currentVersion,
  FlatpakPortal Function()? portalFactory,
  PlatformUpdater? archiveUpdater,
}) {
  if (!host.supportsInAppUpdates) return null;

  if (host.isMacOS) return SparkleUpdateBackend();

  if (host.isFlatpak) {
    final portal = (portalFactory ?? DBusFlatpakPortal.new)();
    return FlatpakUpdateBackend(
      portal: portal,
      releaseNotesUrl: flatpakReleaseNotesUrl(host.flatpakBranch),
    );
  }

  final updater = archiveUpdater ?? PlatformUpdater.forCurrentPlatform();
  if (updater == null) return null;

  return ReleaseUpdateBackend(
    updater: updater,
    currentVersion: currentVersion,
  );
}
