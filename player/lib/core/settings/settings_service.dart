import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/secure_storage_options.dart';

/// Service for managing user settings and preferences.
///
/// Uses secure storage to persist user preferences like default quality
/// and auto-play settings.
class SettingsService {
  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  static const _defaultQualityKey = 'default_quality';
  static const _autoPlayNextKey = 'auto_play_next_episode';

  /// Get the default quality setting.
  Future<String> getDefaultQuality() async {
    final quality = await _storage.read(key: _defaultQualityKey);
    return quality ?? 'auto';
  }

  /// Set the default quality setting.
  Future<void> setDefaultQuality(String quality) async {
    await _storage.write(key: _defaultQualityKey, value: quality);
  }

  /// Get the auto-play next episode setting.
  Future<bool> getAutoPlayNext() async {
    final value = await _storage.read(key: _autoPlayNextKey);
    if (value == null) return true; // Default to enabled
    return value == 'true';
  }

  /// Set the auto-play next episode setting.
  Future<void> setAutoPlayNext(bool enabled) async {
    await _storage.write(key: _autoPlayNextKey, value: enabled.toString());
  }

  /// Clear all settings.
  Future<void> clearSettings() async {
    await Future.wait([
      _storage.delete(key: _defaultQualityKey),
      _storage.delete(key: _autoPlayNextKey),
    ]);
  }
}
