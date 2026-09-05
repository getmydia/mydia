import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../domain/models/app_update.dart';
import '../install_environment.dart';
import '../platform_updater.dart';

/// Linux updater: downloads tar.gz, extracts, and replaces the running binary.
///
/// Refuses an install it cannot write, before downloading anything. Deciding
/// afterwards is what made a Flatpak user pay for a full download to reach a
/// browser tab. `startUpdate` routes Flatpak and read-only installs to their
/// own affordances, so reaching [applyUpdate] on one of them is a programming
/// error rather than a user-facing state.
class LinuxUpdater extends PlatformUpdater {
  /// Overrides the detected install environment. Tests only: a `flutter test`
  /// host reports whatever the runner's own directory happens to be, so the
  /// Flatpak and read-only branches are otherwise unreachable.
  final InstallEnvironment? _environmentOverride;

  LinuxUpdater({InstallEnvironment? environment})
      : _environmentOverride = environment;

  InstallEnvironment get _environment =>
      _environmentOverride ?? InstallEnvironment.detect();

  @override
  bool get canUpdateInPlace => _environment == InstallEnvironment.inPlace;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final environment = _environment;
    if (environment != InstallEnvironment.inPlace) {
      throw StateError(
        'Cannot replace a ${environment.name} install in place. '
        'startUpdate should have routed this elsewhere.',
      );
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

    debugPrint('[LinuxUpdater] Copying files to $installDir');
    final copyResult = await Process.run(
      'cp',
      ['-rf', '$extractDir/.', installDir],
    );
    if (copyResult.exitCode != 0) {
      throw Exception('Failed to copy update files: ${copyResult.stderr}');
    }

    await Process.run('chmod', ['+x', execPath]);

    debugPrint('[LinuxUpdater] Relaunching');
    await Process.start(execPath, [], mode: ProcessStartMode.detached);

    exit(0);
  }
}
