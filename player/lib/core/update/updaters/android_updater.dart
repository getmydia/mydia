import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../domain/models/available_update.dart';
import '../android_installer.dart';
import '../platform_updater.dart';

/// Android: downloads the APK and hands it to the package installer.
///
/// Only sideloaded installs ever reach this. UpdateHost refuses to build a
/// backend for a copy installed from Google Play, because Play forbids an app
/// it distributes from updating itself by any other mechanism.
class AndroidUpdater extends PlatformUpdater {
  AndroidUpdater({
    AndroidInstaller? installer,
    Dio? dio,
    Future<Directory> Function()? cacheDir,
  })  : _installer = installer ?? const AndroidInstaller(),
        _dio = dio ?? Dio(),
        _cacheDir = cacheDir ?? getTemporaryDirectory;

  final AndroidInstaller _installer;
  final Dio _dio;
  final Future<Directory> Function() _cacheDir;

  @override
  bool get canUpdateInPlace => true;

  // install() returns once the session is committed, not once the user has
  // answered Android's own confirmation dialog. A caller that treats a
  // successful applyUpdate as "installed" would be reporting an update that
  // is merely offered, so this tells ReleaseUpdateBackend to report
  // UpdateDeferred instead.
  @override
  bool get handsOffUnconfirmed => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    // Asked before the download, not after it, for the same reason
    // LinuxUpdater checks writability first: a refusal that arrives after 60
    // MB of transfer is a refusal the user paid for twice.
    if (!await _installer.canInstall()) {
      await _installer.requestPermission();
      throw InstallerPermissionDenied();
    }

    final dir = await _cacheDir();
    final file = File('${dir.path}/mydia-player-${update.version}.apk');
    if (file.existsSync()) file.deleteSync();

    debugPrint('[AndroidUpdater] Downloading to ${file.path}');
    await _dio.download(
      update.downloadUrl,
      file.path,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) onProgress(received / total);
      },
    );
    onProgress?.call(1.0);

    final expected = update.sha256;
    if (expected != null) {
      final actual = crypto.sha256.convert(file.readAsBytesSync()).toString();
      if (actual != expected) {
        // Delete first. A file that failed its check must not sit in the
        // cache where a later run could pick it up.
        file.deleteSync();
        throw Exception(
          'The downloaded file does not match its published checksum.',
        );
      }
    }

    await _installer.install(file.path);
  }
}
