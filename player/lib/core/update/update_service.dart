import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/models/available_update.dart';
import '../storage/secure_storage_options.dart';
import 'update_feed_client.dart';
import 'update_track.dart';
import 'version_comparator.dart';

/// Orchestrates update checking: rate-limiting, version comparison, and caching.
class UpdateService {
  static const _lastCheckKey = 'update_last_check_timestamp';
  static const _checkIntervalHours = 24;

  final UpdateFeedClient _client;
  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  UpdateService({UpdateFeedClient? client})
      : _client = client ?? UpdateFeedClient();

  /// Checks for an available update on [track], respecting the 24-hour rate
  /// limit.
  ///
  /// Returns an [AppUpdate] when the feed's entry for this platform and track
  /// is newer than [currentVersion], null otherwise. Pass [force] to bypass
  /// the rate limit, which the manual check does.
  Future<AppUpdate?> checkForUpdate({
    required String currentVersion,
    required UpdateTrack track,
    bool force = false,
  }) async {
    if (kIsWeb) return null;

    if (!force && await _isRateLimited()) {
      debugPrint('[UpdateService] Rate-limited, skipping check');
      return null;
    }

    final platform = UpdateFeedClient.platformSlug();
    if (platform == null) return null;

    final entry = await _client.fetch(track: track, platform: platform);
    await _recordCheckTimestamp();

    if (entry == null) return null;

    if (VersionComparator.isNewer(currentVersion, entry.version)) {
      debugPrint(
          '[UpdateService] ${track.wireName} update available: ${entry.version} (current: $currentVersion)');
      return entry.toAppUpdate();
    }

    debugPrint(
        '[UpdateService] No update needed (current: $currentVersion, ${track.wireName}: ${entry.version})');
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
