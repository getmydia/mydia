import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../../domain/models/available_update.dart';
import '../platform_updater.dart';
import 'linux_updater.dart';

typedef AppImageDownload = Future<void> Function(
  String url,
  String destination,
  void Function(double progress)? onProgress,
);

/// The download is not an AppImage: truncated, or an error page.
class AppImageUpdateException implements Exception {
  const AppImageUpdateException(this.message);
  final String message;
  @override
  String toString() => 'AppImageUpdateException: $message';
}

/// Updates an AppImage by replacing its own `.AppImage` file.
///
/// Downloads beside the file so the final rename stays on one filesystem and
/// is atomic. Linux keeps the running inode alive after the rename, so the
/// old build keeps running until the relaunch. The filename never changes,
/// which keeps desktop entries from AppImageLauncher or Gear Lever working.
class AppImageUpdater extends PlatformUpdater {
  AppImageUpdater({
    required String appImagePath,
    AppImageDownload? download,
    Future<void> Function(String path)? launch,
    Future<void> Function(String url)? openInBrowser,
    void Function()? exitApp,
  })  : _appImagePath = appImagePath,
        _download = download ?? _dioDownload,
        _launch = launch ??
            ((path) =>
                Process.start(path, [], mode: ProcessStartMode.detached)),
        _openInBrowser =
            openInBrowser ?? ((url) async => Process.run('xdg-open', [url])),
        _exitApp = exitApp ?? (() => exit(0));

  final String _appImagePath;
  final AppImageDownload _download;
  final Future<void> Function(String path) _launch;
  final Future<void> Function(String url) _openInBrowser;
  final void Function() _exitApp;

  /// The path of the running `.AppImage` file, or null when this process was
  /// not started from one.
  ///
  /// The AppImage runtime exports APPIMAGE before exec'ing AppRun. The one
  /// definition of "running as an AppImage": the feed slug, the install
  /// probe and updater selection all read it.
  static String? runningAppImagePath() =>
      resolveAppImagePath(Platform.environment);

  @visibleForTesting
  static String? resolveAppImagePath(Map<String, String> environment) {
    final path = environment['APPIMAGE'];
    return (path == null || path.isEmpty) ? null : path;
  }

  String get _directory => File(_appImagePath).parent.path;

  @override
  bool get canUpdateInPlace =>
      LinuxUpdater.installDirWritable(path: _directory);

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    // Before the download, for the reason LinuxUpdater gives.
    if (!canUpdateInPlace) {
      debugPrint('[AppImageUpdater] $_directory not writable, opening browser');
      await _openInBrowser(update.releaseNotesUrl);
      return;
    }

    final name = _appImagePath.split('/').last;
    final temp = File('$_directory/.$name.update-$pid');
    try {
      await _download(update.downloadUrl, temp.path, onProgress);
      _requireAppImage(temp);
      final chmod = await Process.run('chmod', ['755', temp.path]);
      if (chmod.exitCode != 0) {
        throw AppImageUpdateException('chmod failed: ${chmod.stderr}');
      }
      temp.renameSync(_appImagePath);
    } catch (_) {
      if (temp.existsSync()) temp.deleteSync();
      rethrow;
    }

    debugPrint('[AppImageUpdater] Relaunching $_appImagePath');
    await _launch(_appImagePath);
    _exitApp();
  }

  /// ELF magic, then the AppImage type 2 marker ("AI", 0x02) at offset 8.
  static void _requireAppImage(File file) {
    const magic = [0x7f, 0x45, 0x4c, 0x46];
    const marker = [0x41, 0x49, 0x02];
    final raf = file.openSync();
    try {
      final head = raf.readSync(11);
      final ok = head.length == 11 &&
          List.generate(4, (i) => head[i] == magic[i]).every((b) => b) &&
          List.generate(3, (i) => head[8 + i] == marker[i]).every((b) => b);
      if (!ok) {
        throw const AppImageUpdateException('download is not an AppImage');
      }
    } finally {
      raf.closeSync();
    }
  }

  static Future<void> _dioDownload(
    String url,
    String destination,
    void Function(double progress)? onProgress,
  ) =>
      Dio().download(
        url,
        destination,
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );
}
