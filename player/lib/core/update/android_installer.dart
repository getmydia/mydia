import 'package:flutter/services.dart';

/// Method channel to ApkInstaller.kt.
///
/// Exposed rather than private so tests can mock it, matching kSparkleChannel.
const MethodChannel kInstallerChannel =
    MethodChannel('dev.mydia.player/installer');

/// The host side is not present, which is every platform but Android.
class InstallerUnavailable implements Exception {
  @override
  String toString() => 'The Android installer is not available here.';
}

/// The user has not allowed this app to install packages.
class InstallerPermissionDenied implements Exception {
  @override
  String toString() =>
      'Mydia is not allowed to install apps. Turn on "Allow from this source" '
      'for Mydia in Android settings, then try again.';
}

/// Installs an APK through Android's package installer.
class AndroidInstaller {
  const AndroidInstaller({MethodChannel channel = kInstallerChannel})
      : _channel = channel;

  final MethodChannel _channel;

  /// Whether Android will let this app install a package right now.
  ///
  /// False rather than a throw when the host is missing, so a caller on the
  /// wrong platform simply finds it cannot install.
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Opens the system screen where the user grants install permission.
  Future<void> requestPermission() async {
    try {
      await _channel.invokeMethod('requestPermission');
    } on MissingPluginException {
      throw InstallerUnavailable();
    }
  }

  /// Hands [path] to the package installer.
  ///
  /// Returns once the session has been committed, not once the user has
  /// approved it. The confirmation dialog and the actual install happen
  /// afterwards, on Android's own schedule, and are handled entirely on the
  /// platform side (see `ApkInstallReceiver`); nothing comes back through
  /// this call to say whether the user accepted or declined.
  Future<void> install(String path) async {
    try {
      await _channel.invokeMethod('install', {'path': path});
    } on PlatformException catch (e) {
      if (e.code == 'permission_denied') throw InstallerPermissionDenied();
      throw Exception('Install failed: ${e.message ?? e.code}');
    } on MissingPluginException {
      throw InstallerUnavailable();
    }
  }
}
