import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/sources/mydia/mydia_credentials.dart';
import '../../../core/sources/mydia/mydia_source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/settings/settings_providers.dart';
import '../../../core/settings/settings_service.dart';
import '../../../domain/models/user_settings.dart';
import '../../../domain/sources/source_error.dart';

part 'settings_controller.g.dart';

/// Provider for the settings service instance.
///
/// Delegates to `coreSettingsServiceProvider` so an override in a test, or
/// a future change of storage, reaches every reader at once.
@riverpod
SettingsService settingsService(Ref ref) =>
    ref.watch(coreSettingsServiceProvider);

/// Controller for managing user settings.
@riverpod
class SettingsController extends _$SettingsController {
  @override
  Future<UserSettings> build() async {
    return _loadSettings();
  }

  /// Load settings from storage and auth service.
  Future<UserSettings> _loadSettings() async {
    final settingsService = ref.read(settingsServiceProvider);

    // The active Mydia server's own credentials, not the legacy sign-in keys.
    // Watched before any await, so a switch of server reloads this.
    final id = ref.watch(activeSourceIdProvider);
    final source = id == null ? null : ref.watch(mediaSourceProvider(id));
    final accountName =
        source is MydiaSource ? source.source.account.displayName : null;
    MydiaCredentials? credentials;
    if (source is MydiaSource) {
      try {
        credentials = await source.client.credentials();
      } on SourceException {
        credentials = null;
      }
    }
    final defaultQuality = await settingsService.getDefaultQuality();
    final autoSkipSegments = await settingsService.getAutoSkipSegments();

    return UserSettings(
      serverUrl: credentials?.serverUrl ?? accountName ?? '',
      username: credentials?.username ?? '',
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
