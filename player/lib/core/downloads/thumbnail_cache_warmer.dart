import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../domain/models/download.dart';
import '../cache/poster_cache_manager.dart';

/// Warms a completed download's episode thumbnail into the shared image cache
/// so the downloads rails still have artwork when the device is offline.
///
/// Best-effort by design. A download that already succeeded on disk must never
/// be failed by an image fetch, so every error is swallowed.
///
/// [cache] is injectable so tests can supply a fake instead of touching the
/// network or the real cache directory.
Future<void> warmThumbnailCache(
  DownloadTask task, {
  BaseCacheManager? cache,
}) async {
  final url = task.thumbnailUrl;
  if (url == null || url.isEmpty) return;

  try {
    await (cache ?? EpisodeThumbnailCacheManager()).downloadFile(url);
  } catch (e) {
    debugPrint('[Downloads] Thumbnail warm skipped: $e');
  }
}
