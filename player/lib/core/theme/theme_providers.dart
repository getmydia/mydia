import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../settings/settings_providers.dart';
import 'glass_material.dart';
import 'palette.dart';
import 'system_accent.dart';
import 'theme_preset.dart';

part 'theme_providers.g.dart';

/// The theme preset this device uses. Synchronous so the first frame can be
/// themed: it starts on the platform default and moves to the stored choice
/// once storage answers (normally while the loading screen is still up).
@Riverpod(keepAlive: true)
class ThemePresetSetting extends _$ThemePresetSetting {
  /// Set by [set], so a stored read finishing later cannot undo a choice.
  ThemePreset? _selected;

  @override
  ThemePreset build() {
    unawaited(_load());
    return ThemePreset.defaultFor(defaultTargetPlatform);
  }

  Future<void> _load() async {
    try {
      final stored =
          await ref.read(coreSettingsServiceProvider).getThemePreset();
      if (!ref.mounted || _selected != null) return;
      state = ThemePreset.resolve(stored, defaultTargetPlatform);
    } catch (e) {
      debugPrint('[ThemePresetSetting] Could not load: $e');
    }
  }

  /// Applies at once; a failed write keeps the choice for this session and
  /// is only logged.
  Future<void> set(ThemePreset preset) async {
    _selected = preset;
    state = preset;
    try {
      await ref.read(coreSettingsServiceProvider).setThemePreset(preset);
    } catch (e) {
      debugPrint('[ThemePresetSetting] Could not persist: $e');
    }
  }
}

/// The material this device draws controls with. Synchronous for the first
/// frame, like [ThemePresetSetting]: it starts on the platform default and
/// moves to the stored choice once storage answers.
@Riverpod(keepAlive: true)
class GlassMaterialSetting extends _$GlassMaterialSetting {
  /// Set by [set], so a stored read finishing later cannot undo a choice.
  GlassMaterial? _selected;

  @override
  GlassMaterial build() {
    unawaited(_load());
    return GlassMaterial.defaultFor(defaultTargetPlatform);
  }

  Future<void> _load() async {
    try {
      final stored =
          await ref.read(coreSettingsServiceProvider).getGlassMaterial();
      if (!ref.mounted || _selected != null) return;
      state = GlassMaterial.resolve(stored, defaultTargetPlatform);
    } catch (e) {
      debugPrint('[GlassMaterialSetting] Could not load: $e');
    }
  }

  /// Applies at once; a failed write keeps the choice for this session and
  /// is only logged.
  Future<void> set(GlassMaterial material) async {
    _selected = material;
    state = material;
    try {
      await ref.read(coreSettingsServiceProvider).setGlassMaterial(material);
    } catch (e) {
      debugPrint('[GlassMaterialSetting] Could not persist: $e');
    }
  }
}

/// The colours the app is drawn with right now.
@Riverpod(keepAlive: true)
MydiaPalette palette(Ref ref) {
  final preset = ref.watch(themePresetSettingProvider);
  if (preset != ThemePreset.macos) return preset.palette();
  return preset.palette(systemAccent: ref.watch(systemAccentProvider));
}
