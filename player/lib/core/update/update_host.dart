import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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
  }) : assert(
          !isFlatpak || isLinux,
          'Flatpak is a Linux packaging format; isFlatpak implies isLinux.',
        );

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

    return UpdateHost.from(
      isWeb: false,
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      isMacOS: Platform.isMacOS,
      isWindows: Platform.isWindows,
      isLinux: Platform.isLinux,
      flatpak: flatpak,
    );
  }

  /// The host decision itself, separated from the platform lookups so every
  /// combination can be exercised on one machine. Mirrors
  /// PlatformUpdater.supportedOnPlatform, which exists for the same reason.
  @visibleForTesting
  factory UpdateHost.from({
    required bool isWeb,
    required bool isAndroid,
    required bool isIOS,
    required bool isMacOS,
    required bool isWindows,
    required bool isLinux,
    required FlatpakEnvironment flatpak,
  }) {
    // Flatpak is a Linux packaging format. A /.flatpak-info anywhere else is
    // nonsense, and carrying its branch would let a caller build a Flatpak
    // backend on a host that cannot run one.
    final inFlatpak = isLinux && flatpak.isFlatpak;
    return UpdateHost(
      isWeb: isWeb,
      isAndroid: isAndroid,
      isIOS: isIOS,
      isMacOS: isMacOS,
      isWindows: isWindows,
      isLinux: isLinux,
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
  PlatformUpdater? Function()? archiveUpdater,
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

  // A factory rather than a value, so a test can force the null path below
  // without also having to fake the running machine: the one decision this
  // function makes that host.isX does not already cover.
  final updater = (archiveUpdater ?? PlatformUpdater.forCurrentPlatform)();
  if (updater == null) return null;

  return ReleaseUpdateBackend(
    updater: updater,
    currentVersion: currentVersion,
  );
}
