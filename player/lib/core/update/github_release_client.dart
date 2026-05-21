import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import '../../domain/models/app_update.dart';

/// Queries the GitHub Releases API for the latest Mydia player release.
class GitHubReleaseClient {
  static const _repo = 'getmydia/mydia';
  static const _apiBase = 'https://api.github.com';

  final Dio _dio;

  GitHubReleaseClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: _apiBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: {'Accept': 'application/vnd.github.v3+json'},
            ));

  /// Fetches the latest release and returns an [AppUpdate] if a matching
  /// platform asset is found, or null if no asset matches.
  Future<AppUpdate?> fetchLatestRelease() async {
    try {
      final response = await _dio.get('/repos/$_repo/releases/latest');
      final data = response.data as Map<String, dynamic>;

      final tagName = data['tag_name'] as String? ?? '';
      final version = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final htmlUrl = data['html_url'] as String? ?? '';
      final name = data['name'] as String? ?? tagName;
      final publishedAt =
          DateTime.tryParse(data['published_at'] as String? ?? '') ??
              DateTime.now();

      final assets = data['assets'] as List<dynamic>? ?? [];
      final pattern = _platformAssetPattern();
      if (pattern == null) return null;

      for (final asset in assets) {
        final assetMap = asset as Map<String, dynamic>;
        final assetName = assetMap['name'] as String? ?? '';
        if (pattern.hasMatch(assetName)) {
          return AppUpdate(
            version: version,
            downloadUrl: assetMap['browser_download_url'] as String? ?? '',
            downloadSize: assetMap['size'] as int?,
            releaseNotesUrl: htmlUrl,
            releaseTitle: name,
            publishedAt: publishedAt,
          );
        }
      }

      return null;
    } on DioException catch (e) {
      debugPrint('[GitHubReleaseClient] API error: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[GitHubReleaseClient] Unexpected error: $e');
      return null;
    }
  }

  /// Returns a regex matching the expected asset filename for the current platform.
  static RegExp? _platformAssetPattern() {
    if (kIsWeb) return null;
    if (Platform.isWindows) return RegExp(r'player-windows-v.*\.exe$');
    if (Platform.isMacOS) return RegExp(r'player-macos-v.*\.dmg$');
    if (Platform.isLinux) return RegExp(r'player-linux-v.*\.tar\.gz$');
    return null;
  }
}
