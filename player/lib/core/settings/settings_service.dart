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
  static const _crashReportingEnabledKey = 'crash_reporting_enabled';
  static const _calendarViewModeKey = 'calendar_view_mode';
  static const _statsOverlayEnabledKey = 'stats_overlay_enabled';
  static const _updateTrackKey = 'update_track';

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

  /// Whether crash reports are sent to the Mydia developers.
  ///
  /// Off by default, matching the server's own opt-in. A device-level choice
  /// rather than an account preference, so [clearSettings] leaves it alone.
  Future<bool> getCrashReportingEnabled() async {
    final value = await _storage.read(_crashReportingEnabledKey);
    return value == 'true';
  }

  /// Set whether crash reports are sent to the Mydia developers.
  Future<void> setCrashReportingEnabled(bool enabled) async {
    await _storage.write(_crashReportingEnabledKey, enabled.toString());
  }

  /// Whether the playback stats panel is drawn over the video.
  ///
  /// Off by default. A device-level choice like
  /// [getCrashReportingEnabled], so [clearSettings] leaves it alone: a
  /// viewer who turned the panel on does not expect signing out of one
  /// server to turn it off.
  Future<bool> getStatsOverlayEnabled() async {
    final value = await _storage.read(_statsOverlayEnabledKey);
    return value == 'true';
  }

  /// Set whether the playback stats panel is drawn over the video.
  Future<void> setStatsOverlayEnabled(bool enabled) async {
    await _storage.write(_statsOverlayEnabledKey, enabled.toString());
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

  /// Get the remembered calendar layout, as its stored string.
  ///
  /// Returns null when nothing has been stored yet; decoding, including the
  /// default, belongs to the caller.
  Future<String?> getCalendarViewMode() async {
    return _storage.read(_calendarViewModeKey);
  }

  /// Set the remembered calendar layout, as its stored string.
  Future<void> setCalendarViewMode(String mode) async {
    await _storage.write(_calendarViewModeKey, mode);
  }

  /// The release track this install follows, as its stored string.
  ///
  /// A device-level choice rather than an account preference, so
  /// [clearSettings] leaves it alone: signing out of a server says nothing
  /// about which builds this machine should install. Decoding, including the
  /// default, belongs to the caller.
  Future<String?> getUpdateTrack() async => _storage.read(_updateTrackKey);

  /// Set the release track this install follows.
  Future<void> setUpdateTrack(String track) async {
    await _storage.write(_updateTrackKey, track);
  }

  /// Clear all settings.
  ///
  /// Deletes an explicit list of keys, not everything in storage. Device-level
  /// choices are deliberately left out of that list: [_updateTrackKey] and
  /// [_crashReportingEnabledKey] both survive a clear for that reason.
  Future<void> clearSettings() async {
    await Future.wait([
      _storage.delete(_defaultQualityKey),
      _storage.delete(_autoSkipSegmentsKey),
      _storage.delete('${_librarySortKeyPrefix}movies'),
      _storage.delete('${_librarySortKeyPrefix}tvShows'),
      _storage.delete(_calendarViewModeKey),
    ]);
  }
}
