import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'updaters/linux_updater.dart';

/// How the running install can be replaced.
///
/// Answered before anything downloads. The previous arrangement asked the
/// question inside `LinuxUpdater.applyUpdate`, after the archive had already
/// been fetched and extracted, which cost a Flatpak user a full download to
/// reach a browser tab.
enum InstallEnvironment {
  /// The install directory is writable, so the updater can swap the binary.
  inPlace,

  /// Running inside a Flatpak sandbox. The runtime updates through
  /// `flatpak update`, and a downloaded tar.gz is of no use.
  flatpak,

  /// Some other install this process cannot write to: a system-wide tree
  /// under /opt, or a distribution package.
  readOnly;

  /// Resolves the environment for the running process.
  static InstallEnvironment detect() => resolve(
        isLinux: Platform.isLinux,
        flatpakId: Platform.environment['FLATPAK_ID'],
        flatpakInfoExists:
            Platform.isLinux && File('/.flatpak-info').existsSync(),
        installDirWritable: installDirWritable(),
      );

  /// The decision itself, separated from the platform lookups so every branch
  /// is reachable from one test host. Mirrors the split
  /// `PlatformUpdater.supportedOnPlatform` already uses.
  @visibleForTesting
  static InstallEnvironment resolve({
    required bool isLinux,
    required String? flatpakId,
    required bool flatpakInfoExists,
    required bool installDirWritable,
  }) {
    // Windows installs per-user into %LOCALAPPDATA% and runs its own
    // installer, and macOS never reaches here because Sparkle owns the whole
    // flow. Neither has a Flatpak or read-only variant worth branching on,
    // and consulting writability would newly refuse a Windows update that
    // `WindowsUpdater.canUpdateInPlace` has always accepted.
    if (!isLinux) return InstallEnvironment.inPlace;

    if (flatpakId != null && flatpakId.isNotEmpty)
      return InstallEnvironment.flatpak;
    if (flatpakInfoExists) return InstallEnvironment.flatpak;

    return installDirWritable
        ? InstallEnvironment.inPlace
        : InstallEnvironment.readOnly;
  }

  /// Whether [path] is writable, or the directory holding the running
  /// executable when [path] is omitted.
  ///
  /// Delegates to `LinuxUpdater.installDirWritable`, which probes with a real
  /// write rather than reading permission bits. A root-owned 0755 directory
  /// has its owner write bit set, which a bit check reads as writable even
  /// though this process cannot write it; only an actual write tells the
  /// truth. Two implementations of that probe would let this one drift back
  /// to the bit check while the updater's stayed fixed. [path] exists so a
  /// test can point this at a directory it does not own, the way
  /// `LinuxUpdater.installDirWritable`'s own tests do, without the running
  /// executable's directory getting in the way.
  @visibleForTesting
  static bool installDirWritable({String? path}) {
    final target = path ?? File(Platform.resolvedExecutable).parent.path;
    return LinuxUpdater.installDirWritable(path: target);
  }
}
