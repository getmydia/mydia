/// Native implementation for device info using device_info_plus.
library;

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

Future<String> getDeviceName() async {
  final deviceInfo = DeviceInfoPlugin();

  if (Platform.isIOS) {
    final iosInfo = await deviceInfo.iosInfo;
    return iosInfo.name; // e.g., "John's iPhone"
  } else if (Platform.isAndroid) {
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.model; // e.g., "Pixel 7"
  } else if (Platform.isMacOS) {
    final macInfo = await deviceInfo.macOsInfo;
    return macInfo.computerName; // e.g., "John's MacBook Pro"
  } else if (Platform.isWindows) {
    final windowsInfo = await deviceInfo.windowsInfo;
    return windowsInfo.computerName; // e.g., "DESKTOP-ABC123"
  } else if (Platform.isLinux) {
    final linuxInfo = await deviceInfo.linuxInfo;
    return linuxInfo.prettyName; // e.g., "Ubuntu 22.04"
  } else {
    return 'Unknown Device';
  }
}

String getPlatform() {
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}
