import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/auth/auth_service.dart';
import '../../../core/settings/settings_service.dart';
import '../../../domain/models/user_settings.dart';

part 'settings_controller.g.dart';

/// Provider for the settings service instance.
@riverpod
SettingsService settingsService(Ref ref) {
  return SettingsService();
}

/// Controller for managing user settings.
@riverpod
class SettingsController extends _$SettingsController {
  @override
  Future<UserSettings> build() async {
    return _loadSettings();
  }

  /// Load settings from storage and auth service.
  Future<UserSettings> _loadSettings() async {
    final authService = AuthService();
    final settingsService = ref.read(settingsServiceProvider);

    final session = await authService.getSession();
    final defaultQuality = await settingsService.getDefaultQuality();
    final autoSkipSegments = await settingsService.getAutoSkipSegments();

    return UserSettings(
      serverUrl: session['serverUrl'] ?? '',
      username: session['username'] ?? '',
      defaultQuality: defaultQuality,
      autoSkipSegments: autoSkipSegments,
    );
  }

  /// Set the default quality preference.
  Future<void> setDefaultQuality(String quality) async {
    final settingsService = ref.read(settingsServiceProvider);
    await settingsService.setDefaultQuality(quality);

    // Update the state
    state = await AsyncValue.guard(() async {
      final currentSettings = await future;
      return currentSettings.copyWith(defaultQuality: quality);
    });
  }

  /// Set the automatic intro and credits skipping preference.
  Future<void> setAutoSkipSegments(bool enabled) async {
    final settingsService = ref.read(settingsServiceProvider);
    await settingsService.setAutoSkipSegments(enabled);

    // Update the state
    state = await AsyncValue.guard(() async {
      final currentSettings = await future;
      return currentSettings.copyWith(autoSkipSegments: enabled);
    });
  }
}
