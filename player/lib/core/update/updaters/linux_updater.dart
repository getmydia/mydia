import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../domain/models/app_update.dart';
import '../platform_updater.dart';

/// Linux updater: downloads tar.gz, extracts, and replaces the running binary.
///
/// Falls back to opening the download URL in the browser if the install
/// directory is not writable.
class LinuxUpdater extends PlatformUpdater {
  @override
  bool get canUpdateInPlace => _isInstallDirWritable();

  bool _isInstallDirWritable() {
    try {
      final execPath = Platform.resolvedExecutable;
      final installDir = File(execPath).parent;
      return FileSystemEntity.isDirectorySync(installDir.path) &&
          installDir.statSync().mode & 0x80 != 0; // owner write bit
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final archivePath = '${tempDir.path}/mydia-update.tar.gz';
    final extractDir = '${tempDir.path}/mydia-update-extract';

    debugPrint('[LinuxUpdater] Downloading archive to $archivePath');

    final dio = Dio();
    await dio.download(
      update.downloadUrl,
      archivePath,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );

    // Create extraction directory
    final extractDirObj = Directory(extractDir);
    if (extractDirObj.existsSync()) {
      extractDirObj.deleteSync(recursive: true);
    }
    extractDirObj.createSync(recursive: true);

    debugPrint('[LinuxUpdater] Extracting to $extractDir');
    final extractResult =
        await Process.run('tar', ['-xzf', archivePath, '-C', extractDir]);
    if (extractResult.exitCode != 0) {
      throw Exception('Failed to extract update: ${extractResult.stderr}');
    }

    final execPath = Platform.resolvedExecutable;
    final installDir = File(execPath).parent.path;

    // Check if we can write to the install directory
    if (!_isInstallDirWritable()) {
      // Fall back: open download URL in default browser
      debugPrint(
          '[LinuxUpdater] Install dir not writable, opening browser fallback');
      await Process.run('xdg-open', [update.releaseNotesUrl]);
      return;
    }

    // Copy extracted files over current installation
    debugPrint('[LinuxUpdater] Copying files to $installDir');
    final copyResult = await Process.run(
      'cp',
      ['-rf', '$extractDir/.', installDir],
    );
    if (copyResult.exitCode != 0) {
      throw Exception('Failed to copy update files: ${copyResult.stderr}');
    }

    // Ensure binary is executable
    await Process.run('chmod', ['+x', execPath]);

    // Relaunch
    debugPrint('[LinuxUpdater] Relaunching');
    await Process.start(
      execPath,
      [],
      mode: ProcessStartMode.detached,
    );

    exit(0);
  }
}
