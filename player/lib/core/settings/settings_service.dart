import '../auth/auth_storage.dart';

/// Service for managing user settings and preferences.
///
/// Storage goes through [AuthStorage] rather than `FlutterSecureStorage`
/// directly, so every call inherits the platform hardening in
/// `NativeAuthStorage`. Reaching for the plugin directly is what made
/// `clearSettings` throw on the macOS legacy keychain and abort sign-out
/// before it reached the step that ends the session.
class SettingsService {
  /// [storage] is injectable for tests. Production callers use the default,
  /// which is the platform-appropriate implementation.
  SettingsService({AuthStorage? storage})
      : _storage = storage ?? getAuthStorage();

  final AuthStorage _storage;

  static const _defaultQualityKey = 'default_quality';
  static const _autoSkipSegmentsKey = 'auto_skip_segments';
  static const _librarySortKeyPrefix = 'library_sort_';

  /// Get the default quality setting.
  Future<String> getDefaultQuality() async {
    final quality = await _storage.read(_defaultQualityKey);
    return quality ?? 'auto';
  }

  /// Set the default quality setting.
  Future<void> setDefaultQuality(String quality) async {
    await _storage.write(_defaultQualityKey, quality);
  }

  /// Get the automatic intro and credits skipping setting.
  ///
  /// Defaults to disabled: a wrong detection that silently jumps the viewer out
  /// of content is far more annoying than a button they can ignore.
  Future<bool> getAutoSkipSegments() async {
    final value = await _storage.read(_autoSkipSegmentsKey);
    return value == 'true';
  }

  /// Set the automatic intro and credits skipping setting.
  Future<void> setAutoSkipSegments(bool enabled) async {
    await _storage.write(_autoSkipSegmentsKey, enabled.toString());
  }

  /// Get the remembered sort for a library, as its encoded string.
  ///
  /// [libraryKey] is 'movies' or 'tvShows'. Each library remembers its own
  /// ordering, since a preference that suits films rarely suits shows.
  /// Returns null when nothing has been stored yet; decoding, including the
  /// default, belongs to the caller.
  Future<String?> getLibrarySort(String libraryKey) async {
    return _storage.read('$_librarySortKeyPrefix$libraryKey');
  }

  /// Set the remembered sort for a library, as its encoded string.
  Future<void> setLibrarySort(String libraryKey, String encoded) async {
    await _storage.write('$_librarySortKeyPrefix$libraryKey', encoded);
  }

  /// Clear all settings.
  Future<void> clearSettings() async {
    await Future.wait([
      _storage.delete(_defaultQualityKey),
      _storage.delete(_autoSkipSegmentsKey),
      _storage.delete('${_librarySortKeyPrefix}movies'),
      _storage.delete('${_librarySortKeyPrefix}tvShows'),
    ]);
  }
}
