import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'crash_report.dart';

/// Reads the facts every report carries.
///
/// The reporter calls this once, on the first report, so startup pays
/// nothing for it. Uses [defaultTargetPlatform] rather than `dart:io`'s
/// `Platform` so the file compiles on web.
Future<CrashAppContext> loadCrashAppContext() async {
  final package = await PackageInfo.fromPlatform();
  return CrashAppContext(
    version: package.version,
    buildNumber: package.buildNumber,
    platform: crashPlatformName(defaultTargetPlatform),
    osVersion: await _osVersion(),
    environment: crashEnvironment(release: kReleaseMode, profile: kProfileMode),
  );
}

/// The same names `DeviceInfoService.getPlatform` uses.
@visibleForTesting
String crashPlatformName(TargetPlatform platform) => switch (platform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };

/// `prod` in release builds, matching what the server sends in production.
@visibleForTesting
String crashEnvironment({required bool release, required bool profile}) =>
    release ? 'prod' : (profile ? 'profile' : 'dev');

// Version fields only. getDeviceName() in core/auth/ returns the device's
// personal name ("John's iPhone"), which identifies the user, and
// Platform.operatingSystemVersion is the raw kernel string on Android and
// Linux.
Future<String> _osVersion() async {
  final plugin = DeviceInfoPlugin();
  try {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => await plugin.androidInfo.then(
          (i) => 'Android ${i.version.release} (SDK ${i.version.sdkInt})',
        ),
      TargetPlatform.iOS =>
        await plugin.iosInfo.then((i) => 'iOS ${i.systemVersion}'),
      TargetPlatform.macOS =>
        await plugin.macOsInfo.then((i) => 'macOS ${i.osRelease}'),
      TargetPlatform.windows => await plugin.windowsInfo.then(
          (i) => 'Windows ${i.displayVersion} (${i.buildNumber})',
        ),
      TargetPlatform.linux => await plugin.linuxInfo.then((i) => i.prettyName),
      TargetPlatform.fuchsia => 'unknown',
    };
  } catch (e) {
    debugPrint('[CrashReporter] Could not read the OS version: $e');
    return 'unknown';
  }
}
