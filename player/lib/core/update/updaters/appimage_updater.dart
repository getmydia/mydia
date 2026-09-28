import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Updater for the AppImage build. Task 3 fills in the update itself.
class AppImageUpdater {
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
}
