import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:uuid/uuid.dart';

import 'auth_storage.dart';
import 'device_info_service_stub.dart'
    if (dart.library.io) 'device_info_service_native.dart'
    if (dart.library.html) 'device_info_service_web.dart'
    as platform;

/// Service for managing device information and persistent device ID.
///
/// Generates a unique device ID on first launch and stores it securely.
/// Provides device name and platform information for authentication.
class DeviceInfoService {
  final AuthStorage _storage = getAuthStorage();
  static const _deviceIdKey = 'device_id';
  static const _uuid = Uuid();

  /// Get or generate a persistent device ID.
  ///
  /// This ID is generated once and stored securely. It's used to identify
  /// this specific device/installation to the server.
  Future<String> getDeviceId() async {
    // Try to get existing device ID
    final existingId = await _storage.read(_deviceIdKey);
    if (existingId != null) {
      return existingId;
    }

    // Generate new device ID
    final newId = _uuid.v4();
    await _storage.write(_deviceIdKey, newId);
    return newId;
  }

  /// Get the device name (e.g., "John's iPhone", "Chrome on Windows").
  Future<String> getDeviceName() async {
    return await platform.getDeviceName();
  }

  /// Get the platform identifier (ios, android, web, macos, windows, linux).
  String getPlatform() {
    if (kIsWeb) return 'web';
    return platform.getPlatform();
  }

  /// Clear the stored device ID (for logout/reset).
  Future<void> clearDeviceId() async {
    await _storage.delete(_deviceIdKey);
  }
}
