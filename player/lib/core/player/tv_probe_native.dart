/// Native half of the television probe.
///
/// `android.software.leanback` is the feature Android TV and Google TV devices
/// declare, and it is what `PackageManager.hasSystemFeature` is checked
/// against by every leanback-aware app. `device_info_plus` already surfaces
/// the full feature list, so this needs no platform channel of its own.
library;

import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// The feature string a television declares.
const String _leanbackFeature = 'android.software.leanback';

/// Whether this device declares itself a television.
///
/// Returns false on any failure. A probe that cannot answer must not strand
/// the app in a mode nobody asked for, and the phone and desktop behaviour is
/// the safe default in both directions.
Future<bool> probeLeanback() async {
  if (!Platform.isAndroid) return false;
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.systemFeatures.contains(_leanbackFeature);
  } catch (e) {
    debugPrint('[TvProbe] Failed to read Android system features: $e');
    return false;
  }
}
