import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../domain/models/available_update.dart';
import '../platform_updater.dart';

/// Linux updater: downloads tar.gz, extracts, and replaces the running binary.
///
/// Falls back to opening the download URL in the browser if the install
/// directory is not writable.
class LinuxUpdater extends PlatformUpdater {
  /// Both seams exist for tests. Production uses the defaults, which resolve
  /// the running binary and hand the URL to xdg-open.
  LinuxUpdater({
    String Function()? resolveInstallDir,
    Future<void> Function(String url)? openInBrowser,
  })  : _resolveInstallDir = resolveInstallDir ??
            (() => File(Platform.resolvedExecutable).parent.path),
        _openInBrowser =
            openInBrowser ?? ((url) async => Process.run('xdg-open', [url]));

  final String Function() _resolveInstallDir;
  final Future<void> Function(String url) _openInBrowser;

  @override
  bool get canUpdateInPlace => installDirWritable(path: _resolveInstallDir());

  /// Whether files can actually be created in [path].
  ///
  /// The permission bits are not the answer. Inside the Flatpak sandbox
  /// /app/lib/mydia-player is 0755 and owned by the running user, so the
  /// owner write bit is set, while the mount itself is read-only. The old
  /// check read that bit, returned true, and the updater committed to an
  /// update it could not perform. Only a write tells the truth.
  static bool installDirWritable({required String path}) {
    final probe = File(
      '$path/.mydia-update-probe-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      probe.createSync(exclusive: true);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        if (probe.existsSync()) probe.deleteSync();
      } catch (_) {
        // A probe we could not remove is not worth failing an update over.
      }
    }
  }

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final installDir = _resolveInstallDir();

    // Before the download, not after it. The old order fetched roughly 60 MB
    // and only then discovered it had nowhere to put it.
    if (!installDirWritable(path: installDir)) {
      debugPrint('[LinuxUpdater] Install dir not writable, opening browser');
      await _openInBrowser(update.releaseNotesUrl);
      return;
    }

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
