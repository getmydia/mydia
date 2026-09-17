import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/models/available_update.dart';
import 'backends/flatpak_update_backend.dart';
import 'backends/release_update_backend.dart';
import 'backends/sparkle_update_backend.dart';
import 'flatpak_environment.dart';
import 'flatpak_portal.dart';
import 'platform_updater.dart';
import 'update_backend.dart';
import 'update_track.dart';

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

  /// True when this copy was installed by the Play Store.
  ///
  /// Play forbids an app it distributes from updating itself by any mechanism
  /// other than Play's own, so a Play install gets no backend at all and no
  /// update row, exactly as before this existed.
  final bool installedFromPlay;

  const UpdateHost({
    required this.isWeb,
    required this.isAndroid,
    required this.isIOS,
    required this.isMacOS,
    required this.isWindows,
    required this.isLinux,
    this.isFlatpak = false,
    this.flatpakBranch,
    this.installedFromPlay = false,
  }) : assert(
          !isFlatpak || isLinux,
          'Flatpak is a Linux packaging format; isFlatpak implies isLinux.',
        );

  ///
  /// Cannot tell a sideloaded Android install from a Play one, since that
  /// takes an async platform call. Defaults [installedFromPlay] to true on
  /// Android, so a caller that skips [currentAsync] never accidentally
  /// enables a Play self-updater. Kept for the places that cannot await;
  /// prefer [currentAsync] everywhere else.
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
      installedFromPlay: Platform.isAndroid,
    );
  }

  /// Same as [current], but able to ask Android which store installed this
  /// copy.
  static Future<UpdateHost> currentAsync({
    FlatpakEnvironment flatpak = const FlatpakEnvironment(),
  }) async {
    if (kIsWeb) return UpdateHost.current(flatpak: flatpak);

    var fromPlay = false;
    if (Platform.isAndroid) {
      try {
        final info = await PackageInfo.fromPlatform();
        fromPlay = info.installerStore == 'com.android.vending';
      } catch (e) {
        // Unknown provenance is treated as Play. Refusing to self-update is
        // the safe direction: the worst case is an Android user who keeps
        // updating by hand, against a policy violation on the listing.
        debugPrint('[UpdateHost] could not read the installer store: $e');
        fromPlay = true;
      }
    }

    return UpdateHost.from(
      isWeb: false,
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      isMacOS: Platform.isMacOS,
      isWindows: Platform.isWindows,
      isLinux: Platform.isLinux,
      flatpak: flatpak,
      installedFromPlay: fromPlay,
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
    bool installedFromPlay = false,
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
      installedFromPlay: installedFromPlay,
    );
  }

  /// iOS updates through the App Store and web is served by the Mydia
  /// server, so neither can replace the running app. Android can, when it
  /// was sideloaded.
  bool get supportsInAppUpdates {
    if (isWeb || isIOS) return false;
    if (isAndroid) return !installedFromPlay;
    return true;
  }
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
      branch: host.flatpakBranch,
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
    // This branch is Windows, non-Flatpak Linux, and sideloaded Android (the
    // isMacOS and isFlatpak cases above already returned, and a Play install
    // never reaches here: supportsInAppUpdates excludes it before this
    // function gets this far). Android is the one platform of the three that
    // publishes dev builds, so it alone gets the full set. Add
    // UpdateTrack.dev for Windows or Linux the day dev builds start
    // publishing there too; until then it would offer a picker choice that
    // resolves to nothing.
    availableTracks: host.isAndroid
        ? const {UpdateTrack.stable, UpdateTrack.beta, UpdateTrack.dev}
        : const {UpdateTrack.stable, UpdateTrack.beta},
  );
}
