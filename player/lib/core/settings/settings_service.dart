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
  static const _autoSkipSegmentsKey = 'auto_skip_segments';

  /// Get the default quality setting.
  Future<String> getDefaultQuality() async {
    final quality = await _storage.read(key: _defaultQualityKey);
    return quality ?? 'auto';
  }

  /// Set the default quality setting.
  Future<void> setDefaultQuality(String quality) async {
    await _storage.write(key: _defaultQualityKey, value: quality);
  }

  /// Get the automatic intro and credits skipping setting.
  ///
  /// Defaults to disabled: a wrong detection that silently jumps the viewer out
  /// of content is far more annoying than a button they can ignore.
  Future<bool> getAutoSkipSegments() async {
    final value = await _storage.read(key: _autoSkipSegmentsKey);
    return value == 'true';
  }

  /// Set the automatic intro and credits skipping setting.
  Future<void> setAutoSkipSegments(bool enabled) async {
    await _storage.write(key: _autoSkipSegmentsKey, value: enabled.toString());
  }

  /// Clear all settings.
  Future<void> clearSettings() async {
    await Future.wait([
      _storage.delete(key: _defaultQualityKey),
      _storage.delete(key: _autoSkipSegmentsKey),
    ]);
  }
}
