import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/models/app_update.dart';
import '../storage/secure_storage_options.dart';
import 'github_release_client.dart';
import 'version_comparator.dart';

/// Orchestrates update checking: rate-limiting, version comparison, and caching.
class UpdateService {
  static const _lastCheckKey = 'update_last_check_timestamp';
  static const _checkIntervalHours = 24;

  final GitHubReleaseClient _client;
  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  UpdateService({GitHubReleaseClient? client})
      : _client = client ?? GitHubReleaseClient();

  /// Checks for an available update, respecting the 24-hour rate limit.
  ///
  /// Returns an [AppUpdate] if a newer version is available, null otherwise.
  /// Pass [force] = true to bypass the rate limit (e.g. manual "Check for Updates").
  Future<AppUpdate?> checkForUpdate({
    required String currentVersion,
    bool force = false,
  }) async {
    if (kIsWeb) return null;

    if (!force && await _isRateLimited()) {
      debugPrint('[UpdateService] Rate-limited, skipping check');
      return null;
    }

    final update = await _client.fetchLatestRelease();
    await _recordCheckTimestamp();

    if (update == null) return null;

    if (VersionComparator.isNewer(currentVersion, update.version)) {
      debugPrint(
          '[UpdateService] Update available: ${update.version} (current: $currentVersion)');
      return update;
    }

    debugPrint(
        '[UpdateService] No update needed (current: $currentVersion, latest: ${update.version})');
    return null;
  }

  Future<bool> _isRateLimited() async {
    final lastCheck = await _storage.read(key: _lastCheckKey);
    if (lastCheck == null) return false;

    final lastTimestamp = DateTime.tryParse(lastCheck);
    if (lastTimestamp == null) return false;

    final elapsed = DateTime.now().difference(lastTimestamp);
    return elapsed.inHours < _checkIntervalHours;
  }

  Future<void> _recordCheckTimestamp() async {
    await _storage.write(
      key: _lastCheckKey,
      value: DateTime.now().toIso8601String(),
    );
  }
}
