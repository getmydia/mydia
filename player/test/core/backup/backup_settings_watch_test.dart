import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/player/subtitle_language_prefs.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/theme_preset.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  late Directory tempDir;
  late Box<List<dynamic>> box;
  late SettingsService settings;
  late int dirty;
  late Future<void> Function() stop;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_settings_watch');
    Hive.init(tempDir.path);
    box = await Hive.openBox<List<dynamic>>(SubtitleLanguagePrefs.boxName);
    settings = SettingsService(storage: MockAuthStorage());
    dirty = 0;
    stop = watchBackedUpSettings(() => dirty++);
  });

  tearDown(() async {
    await stop();
    await box.close();
    await Hive.deleteBoxFromDisk(SubtitleLanguagePrefs.boxName);
    await tempDir.delete(recursive: true);
  });

  // The change streams deliver asynchronously.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('a backed-up setting written through the service marks dirty', () async {
    await settings.setDefaultQuality('1080p');
    await settle();
    expect(dirty, 1);

    await settings.setThemePreset(ThemePreset.values.first);
    await settings.setLocaleCode(null);
    await settle();
    expect(dirty, 3);
  });

  test('a library sort marks dirty', () async {
    await settings.setLibrarySort('lib-night-harbor', 'title:asc');
    await settle();
    expect(dirty, greaterThanOrEqualTo(1));
  });

  test('a setting outside the allowlist does not', () async {
    await settings.setGlassMaterial(GlassMaterial.values.first);
    await settings.setStatsOverlayEnabled(true);
    await settle();
    expect(dirty, 0);
  });

  test('saving subtitle search languages marks dirty', () async {
    await SubtitleLanguagePrefs.save(['pt', 'en']);
    await settle();
    expect(dirty, 1);
  });

  test('a cancelled watch hears nothing', () async {
    await stop();
    await settings.setDefaultQuality('720p');
    await settle();
    expect(dirty, 0);
  });
}
