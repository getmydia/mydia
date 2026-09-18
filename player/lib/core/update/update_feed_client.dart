import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;

import '../../domain/models/available_update.dart';
import 'update_track.dart';

/// One build, as releases.json describes it.
class FeedEntry {
  final String version;
  final int build;
  final String url;
  final int? size;

  /// Present for dev builds, which are not signed by a store or a release
  /// pipeline, and null for release assets. The Android updater refuses to
  /// install a file whose digest is given and does not match.
  final String? sha256;

  final String notesUrl;
  final DateTime publishedAt;

  const FeedEntry({
    required this.version,
    required this.build,
    required this.url,
    required this.size,
    required this.sha256,
    required this.notesUrl,
    required this.publishedAt,
  });

  AppUpdate toAppUpdate() => AppUpdate(
        version: version,
        downloadUrl: url,
        downloadSize: size,
        sha256: sha256,
        releaseNotesUrl: notesUrl,
        releaseTitle: version,
        publishedAt: publishedAt,
      );

  static FeedEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final version = value['version'];
    final build = value['build'];
    final url = value['url'];
    final notesUrl = value['notes_url'];
    if (version is! String || build is! int || url is! String) return null;

    return FeedEntry(
      version: version,
      build: build,
      url: url,
      size: value['size'] is int ? value['size'] as int : null,
      sha256: value['sha256'] is String ? value['sha256'] as String : null,
      notesUrl: notesUrl is String ? notesUrl : url,
      publishedAt: DateTime.tryParse(value['published_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// Reads updates.mydia.dev/releases.json.
///
/// This replaced GitHubReleaseClient, which could only ever see stable:
/// GitHub's /releases/latest skips prereleases by design, so beta and dev
/// were unreachable from the app no matter what the user chose. The feed also
/// carries the dev builds, which never become GitHub releases at all.
class UpdateFeedClient {
  static const defaultFeedUrl = 'https://updates.mydia.dev/releases.json';

  final Dio _dio;
  final String _feedUrl;

  UpdateFeedClient({Dio? dio, String feedUrl = defaultFeedUrl})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
            )),
        _feedUrl = feedUrl;

  /// The feed key for the running platform, or null where the player does not
  /// update itself (web, iOS).
  static String? platformSlug() => resolveSlug(
        isWeb: kIsWeb,
        isAndroid: !kIsWeb && Platform.isAndroid,
        isWindows: !kIsWeb && Platform.isWindows,
        isLinux: !kIsWeb && Platform.isLinux,
        isMacOS: !kIsWeb && Platform.isMacOS,
      );

  /// The mapping itself, separated from the platform lookups so every branch
  /// is reachable from one test host. Mirrors the split UpdateHost.from and
  /// InstallEnvironment.resolve already use for the same problem: a platform
  /// swap here has nothing exercising it, since [platformSlug] previously
  /// could only ever be called against whatever machine happened to run the
  /// test.
  @visibleForTesting
  static String? resolveSlug({
    required bool isWeb,
    required bool isAndroid,
    required bool isWindows,
    required bool isLinux,
    required bool isMacOS,
  }) {
    if (isWeb) return null;
    if (isAndroid) return 'android';
    if (isWindows) return 'windows';
    if (isLinux) return 'linux';
    if (isMacOS) return 'macos';
    return null;
  }

  /// The newest build for [platform] on [track], or null when the feed has
  /// none, cannot be read, or does not parse.
  ///
  /// Null rather than a throw for every failure: a feed outage must leave the
  /// app exactly as it was, not put an error in front of someone who did not
  /// ask for an update.
  Future<FeedEntry?> fetch({
    required UpdateTrack track,
    required String platform,
  }) async {
    try {
      final response = await _dio.get<Object?>(_feedUrl);
      final data = response.data;
      if (data is! Map) return null;

      final platforms = data['platforms'];
      if (platforms is! Map) return null;

      final tracks = platforms[platform];
      if (tracks is! Map) return null;

      return FeedEntry.fromJson(tracks[track.wireName]);
    } on DioException catch (e) {
      debugPrint('[UpdateFeedClient] feed request failed: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('[UpdateFeedClient] unexpected error: $e');
      return null;
    }
  }
}
