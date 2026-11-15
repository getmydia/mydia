import 'dart:async';
import 'dart:convert';

import '../auth/auth_storage.dart';
import '../player/subtitle_size.dart';
import '../theme/glass_material.dart';
import '../theme/theme_preset.dart';

/// Service for managing user settings and preferences.
///
/// Storage goes through [AuthStorage] rather than `FlutterSecureStorage`
/// directly, so every call inherits the platform hardening in
/// `NativeAuthStorage`. Reaching for the plugin directly is what made
/// `clearSettings` throw on the macOS legacy keychain and abort sign-out before
/// it reached the step that ends the session.
class SettingsService {
  /// [storage] is injectable for tests. Production callers use the default,
  /// which is the platform-appropriate implementation.
  SettingsService({AuthStorage? storage})
      : _storage = storage ?? getAuthStorage();

  final AuthStorage _storage;

  static const _defaultQualityKey = 'default_quality';
  static const _autoSkipSegmentsKey = 'auto_skip_segments';
  static const _librarySortKeyPrefix = 'library_sort_';
  static const _statsOverlayEnabledKey = 'stats_overlay_enabled';
  static const _subtitleSizeKey = 'subtitle_size';
  static const _updateTrackKey = 'update_track';
  static const _themePresetKey = 'theme_preset';
  static const _glassMaterialKey = 'glass_material';
  static const _localeKey = 'interface_locale';

  /// The library keys [setLibrarySort] has stored, as a JSON list, so the
  /// cloud backup can find them: secure storage cannot list its keys. Not
  /// under [_librarySortKeyPrefix], so it is never taken for a sort.
  static const _librarySortIndexKey = 'library_sorts_index';

  /// Library keys stored before [_librarySortIndexKey] existed.
  static const _legacyLibrarySortKeys = ['movies', 'tvShows'];

  /// The storage key of every value written or deleted through any
  /// [SettingsService], after the write. Static because several instances
  /// exist (the provider's, `UpdateTrackStore`'s); the cloud backup listens
  /// to upload a backed-up setting that changed.
  static Stream<String> get changes => _changes.stream;
  static final _changes = StreamController<String>.broadcast();

  Future<void> _write(String key, String value) async {
    await _storage.write(key, value);
    _changes.add(key);
  }

  Future<void> _delete(String key) async {
    await _storage.delete(key);
    _changes.add(key);
  }

  /// Get the default quality setting.
  Future<String> getDefaultQuality() async {
    final quality = await _storage.read(_defaultQualityKey);
    return quality ?? 'auto';
  }

  /// Set the default quality setting.
  Future<void> setDefaultQuality(String quality) async {
    await _write(_defaultQualityKey, quality);
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
    await _write(_autoSkipSegmentsKey, enabled.toString());
  }

  /// Whether the playback stats panel is drawn over the video.
  ///
  /// Off by default. A device-level choice, so [clearSettings] leaves it
  /// alone: a viewer who turned the panel on does not expect signing out of
  /// one server to turn it off.
  Future<bool> getStatsOverlayEnabled() async {
    final value = await _storage.read(_statsOverlayEnabledKey);
    return value == 'true';
  }

  /// Set whether the playback stats panel is drawn over the video.
  Future<void> setStatsOverlayEnabled(bool enabled) async {
    await _write(_statsOverlayEnabledKey, enabled.toString());
  }

  /// How large text subtitles are drawn on this device.
  ///
  /// Medium by default. A device-level choice, like the stats overlay, so
  /// [clearSettings] leaves it alone: the right size for a phone is wrong
  /// for a TV, and signing out of a server is not a reason to lose it.
  Future<SubtitleSize> getSubtitleSize() async =>
      SubtitleSize.fromStorageKey(await _storage.read(_subtitleSizeKey));

  /// Set how large text subtitles are drawn on this device.
  Future<void> setSubtitleSize(SubtitleSize size) async {
    await _write(_subtitleSizeKey, size.name);
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
    await _write('$_librarySortKeyPrefix$libraryKey', encoded);
    if (_legacyLibrarySortKeys.contains(libraryKey)) return;
    final known = await _librarySortIndex();
    if (known.contains(libraryKey)) return;
    await _write(_librarySortIndexKey, jsonEncode([...known, libraryKey]));
  }

  /// The storage key of every library sort this device may hold, stored or
  /// cleared. For the cloud backup.
  Future<List<String>> librarySortStorageKeys() async => [
        for (final k in {
          ..._legacyLibrarySortKeys,
          ...await _librarySortIndex()
        })
          '$_librarySortKeyPrefix$k',
      ];

  Future<List<String>> _librarySortIndex() async {
    final raw = await _storage.read(_librarySortIndexKey);
    if (raw == null) return const [];
    try {
      return List<String>.from(jsonDecode(raw) as List);
    } catch (_) {
      return const [];
    }
  }

  /// Whether [storageKey] is a library sort key, as
  /// [librarySortStorageKeys] lists them.
  static bool isLibrarySortKey(String storageKey) =>
      storageKey.startsWith(_librarySortKeyPrefix) &&
      storageKey.length > _librarySortKeyPrefix.length;

  /// The stored string under [storageKey], for the cloud backup, which
  /// decides which keys it may read.
  Future<String?> readStoredValue(String storageKey) =>
      _storage.read(storageKey);

  /// Writes [value] under [storageKey], or deletes it when null, for a
  /// cloud backup restore. A library sort goes through [setLibrarySort] so
  /// it is indexed.
  Future<void> writeStoredValue(String storageKey, String? value) async {
    if (value == null) return _delete(storageKey);
    if (isLibrarySortKey(storageKey)) {
      return setLibrarySort(
          storageKey.substring(_librarySortKeyPrefix.length), value);
    }
    await _write(storageKey, value);
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
    await _write(_updateTrackKey, track);
  }

  /// The theme preset this device uses, as its stored name.
  ///
  /// A device-level choice like the subtitle size, so [clearSettings] leaves
  /// it alone. Decoding, including the platform default, belongs to
  /// `ThemePreset.resolve`.
  Future<String?> getThemePreset() async => _storage.read(_themePresetKey);

  /// Set the theme preset this device uses.
  Future<void> setThemePreset(ThemePreset preset) async {
    await _write(_themePresetKey, preset.name);
  }

  /// The material this device draws controls with, as its stored name.
  ///
  /// Device-level like the theme preset, so [clearSettings] leaves it alone.
  /// Decoding, including the platform default, belongs to
  /// `GlassMaterial.resolve`.
  Future<String?> getGlassMaterial() async => _storage.read(_glassMaterialKey);

  /// Set the material this device draws controls with.
  Future<void> setGlassMaterial(GlassMaterial material) async {
    await _write(_glassMaterialKey, material.name);
  }

  /// The interface language this device uses, as a language tag, or null to
  /// follow the device. Device-level like the theme preset, so
  /// [clearSettings] leaves it alone. Validation belongs to `LocaleSetting`.
  Future<String?> getLocaleCode() async => _storage.read(_localeKey);

  /// Set the interface language; null returns to the device language.
  Future<void> setLocaleCode(String? code) async {
    if (code == null) {
      await _delete(_localeKey);
    } else {
      await _write(_localeKey, code);
    }
  }

  /// Clear all settings.
  ///
  /// Deletes an explicit list of keys, not everything in storage. Device-level
  /// choices are deliberately left out of that list: [_updateTrackKey]
  /// [_themePresetKey], [_glassMaterialKey] and [_localeKey] survive a clear
  /// for that reason,
  /// as does the Diagnostics choice in `DiagnosticsSettings`.
  Future<void> clearSettings() async {
    await Future.wait([
      _delete(_defaultQualityKey),
      _delete(_autoSkipSegmentsKey),
      _delete('${_librarySortKeyPrefix}movies'),
      _delete('${_librarySortKeyPrefix}tvShows'),
    ]);
  }
}
