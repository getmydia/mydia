import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../../../domain/models/available_update.dart';
import '../platform_updater.dart';

/// Windows updater: downloads the Inno Setup installer and runs it silently.
///
/// Because the installer targets per-user install ({localappdata}), no UAC
/// elevation is required.
class WindowsUpdater extends PlatformUpdater {
  @override
  bool get canUpdateInPlace => true;

  @override
  Future<void> applyUpdate(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final installerPath =
        '${tempDir.path}${Platform.pathSeparator}mydia-update.exe';

    debugPrint('[WindowsUpdater] Downloading installer to $installerPath');

    final dio = Dio();
    await dio.download(
      update.downloadUrl,
      installerPath,
      onReceiveProgress: (received, total) {
        if (total > 0 && onProgress != null) {
          onProgress(received / total);
        }
      },
    );

    debugPrint('[WindowsUpdater] Launching silent installer');
    await Process.start(
      installerPath,
      ['/SILENT'],
      mode: ProcessStartMode.detached,
    );

    exit(0);
  }
}
