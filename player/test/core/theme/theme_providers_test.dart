import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/core/theme/system_accent.dart';
import 'package:player/core/theme/theme_preset.dart';
import 'package:player/core/theme/theme_providers.dart';

import '../../test_utils/mock_auth_storage.dart';

class _FixedAccent extends SystemAccent {
  _FixedAccent(this.color);
  final Color color;
  @override
  Color build() => color;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  ProviderContainer containerWith(
    MockAuthStorage storage, {
    Color accent = Palettes.macosDefaultAccent,
  }) {
    final c = ProviderContainer(overrides: [
      coreSettingsServiceProvider
          .overrideWithValue(SettingsService(storage: storage)),
      systemAccentProvider.overrideWith(() => _FixedAccent(accent)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts on the platform default before storage answers', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = containerWith(MockAuthStorage());
    expect(c.read(themePresetSettingProvider), ThemePreset.macos);
  });

  test('loads the stored preset', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await SettingsService(storage: storage).setThemePreset(ThemePreset.slate);
    final c = containerWith(storage);
    c.read(themePresetSettingProvider);
    await settle();
    expect(c.read(themePresetSettingProvider), ThemePreset.slate);
  });

  test('a stored macOS preset falls back off macOS', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await storage.write('theme_preset', 'macos');
    final c = containerWith(storage);
    c.read(themePresetSettingProvider);
    await settle();
    expect(c.read(themePresetSettingProvider), ThemePreset.projectionBooth);
  });

  test('set publishes at once and persists', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    final c = containerWith(storage);
    await c
        .read(themePresetSettingProvider.notifier)
        .set(ThemePreset.oledBlack);
    expect(c.read(themePresetSettingProvider), ThemePreset.oledBlack);
    expect(storage.contents['theme_preset'], 'oledBlack');
  });

  test('a choice made before the stored read lands is kept', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await storage.write('theme_preset', 'slate');
    final c = containerWith(storage);
    c.read(themePresetSettingProvider);
    unawaited(
        c.read(themePresetSettingProvider.notifier).set(ThemePreset.oledBlack));
    await settle();
    expect(c.read(themePresetSettingProvider), ThemePreset.oledBlack);
  });

  test('the macOS palette follows the system accent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = containerWith(MockAuthStorage(), accent: const Color(0xFF30D158));
    expect(c.read(paletteProvider).primary, const Color(0xFF30D158));
  });

  test('other presets ignore the system accent', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final c = containerWith(MockAuthStorage(), accent: const Color(0xFF30D158));
    await c.read(themePresetSettingProvider.notifier).set(ThemePreset.slate);
    expect(c.read(paletteProvider), Palettes.slate);
  });
}
