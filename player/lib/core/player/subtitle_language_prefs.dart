import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce_flutter/hive_flutter.dart';

/// Remembers which languages the user last searched subtitles for.
///
/// Local only, on purpose: subtitle acquisition is manual, so there is no
/// server-side preference to keep in step. A bare static facade rather than
/// the store-plus-provider split `HiveSidebarLayoutStore` and
/// `HiveWindowGeometryStore` use, because the subtitle sheet calls this
/// directly from `initState` with no `ProviderScope` in reach (see its
/// tests). Startup opens the box ([open]) with the app's other boxes, and
/// [load]/[save] only use it once it is open under [boxName]; a test opens
/// the box itself with `Hive.init(tempDir)`. They never open it lazily: a
/// widget test that mounts the subtitle sheet would start that open in its
/// fake async zone, where it never finishes, and Hive would make every later
/// open of the same name in CI's one-isolate bundle wait on it for good.
///
/// Any failure to open or read the box falls back to [defaults] rather than
/// throwing, the same trade `HiveWindowGeometryStore` and
/// `HiveSidebarLayoutStore` make: a broken box costs this feature its
/// persistence for the session, never the feature itself.
class SubtitleLanguagePrefs {
  static const boxName = 'subtitle_search_languages';

  /// There is one search, so one key.
  static const _key = 'languages';

  /// Device locale plus English, which is what most releases carry.
  static List<String> get defaults {
    try {
      final locale = PlatformDispatcher.instance.locale.languageCode;
      return locale == 'en' ? const ['en'] : [locale, 'en'];
    } catch (e) {
      // dart:ui's PlatformDispatcher is always present once the engine has
      // booted, but this getter runs at widget field-initializer time, so it
      // is guarded rather than trusted -- a locale lookup failing must never
      // be the reason subtitle search cannot start.
      debugPrint('[SubtitleLanguagePrefs] Locale lookup failed: $e');
      return const ['en'];
    }
  }

  static Future<List<String>> load() async {
    try {
      final box = await _box();
      final saved = box.get(_key);
      if (saved == null || saved.isEmpty) return defaults;
      // Eagerly validated here, inside the try: a lazy `.cast<String>()`
      // would defer a `TypeError` on a malformed record to whenever the
      // caller iterates the list, past where this can catch it.
      return List<String>.from(saved);
    } catch (e) {
      debugPrint('[SubtitleLanguagePrefs] Box unavailable, using defaults: $e');
      return defaults;
    }
  }

  /// The saved list, or null when none was saved (or the box is
  /// unavailable). The cloud backup reads this rather than [load], so an
  /// install never backs up its locale defaults as a choice.
  static Future<List<String>?> loadSaved() async {
    try {
      final saved = (await _box()).get(_key);
      if (saved == null || saved.isEmpty) return null;
      return List<String>.from(saved);
    } catch (e) {
      debugPrint('[SubtitleLanguagePrefs] Box unavailable: $e');
      return null;
    }
  }

  /// Fires after every [save] that persisted. The cloud backup listens.
  static Stream<void> get changes => _changes.stream;
  static final _changes = StreamController<void>.broadcast();

  static Future<void> save(List<String> languages) async {
    try {
      final box = await _box();
      await box.put(_key, languages);
      _changes.add(null);
    } catch (e) {
      debugPrint('[SubtitleLanguagePrefs] Box unavailable, not persisting: $e');
    }
  }

  /// Opens the box. Startup calls this after `initAppHive`; never throws.
  static Future<void> open() async {
    try {
      await Hive.openBox<List<dynamic>>(boxName);
    } catch (e) {
      debugPrint('[SubtitleLanguagePrefs] Box did not open: $e');
    }
  }

  static Future<Box<List<dynamic>>> _box() async {
    if (Hive.isBoxOpen(boxName)) return Hive.box<List<dynamic>>(boxName);
    throw StateError('$boxName is not open');
  }
}
