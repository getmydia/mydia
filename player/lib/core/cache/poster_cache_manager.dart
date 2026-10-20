import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Custom cache manager for movie and TV show posters.
///
/// Provides aggressive caching for poster images to minimize network requests
/// and improve performance on mobile and desktop platforms.
///
/// Cache Strategy:
/// - Maximum of 500 cached images (sufficient for large libraries)
/// - Images cached for 90 days (posters rarely change)
/// - Uses 'posterCache' as the cache key for isolation from other caches
class PosterCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'posterCache';
  static PosterCacheManager? _instance;

  factory PosterCacheManager() {
    _instance ??= PosterCacheManager._();
    return _instance!;
  }

  PosterCacheManager._()
      : super(
          Config(
            key,
            // Cache up to 500 poster images (should handle most libraries)
            maxNrOfCacheObjects: 500,
            // Keep posters cached for 90 days since they rarely change
            stalePeriod: const Duration(days: 90),
            // Store in dedicated posterCache directory
            fileService: HttpFileService(),
          ),
        );
}

/// Custom cache manager for backdrop images (wide landscape artwork).
///
/// Backdrop images are used in detail screens and hero sections.
///
/// Cache Strategy:
/// - Maximum of 200 cached images (fewer than posters, one per movie/show)
/// - Images cached for 90 days (backdrops rarely change)
/// - Uses 'backdropCache' as the cache key
class BackdropCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'backdropCache';
  static BackdropCacheManager? _instance;

  factory BackdropCacheManager() {
    _instance ??= BackdropCacheManager._();
    return _instance!;
  }

  BackdropCacheManager._()
      : super(
          Config(
            key,
            // Cache up to 200 backdrop images
            maxNrOfCacheObjects: 200,
            // Keep backdrops cached for 90 days
            stalePeriod: const Duration(days: 90),
            fileService: HttpFileService(),
          ),
        );
}

/// Custom cache manager for episode thumbnails.
///
/// Episode thumbnails are used in season lists and episode cards.
///
/// Cache Strategy:
/// - Maximum of 1000 cached images (more episodes than shows)
/// - Images cached for 90 days (thumbnails rarely change)
/// - Uses 'episodeThumbnailCache' as the cache key
class EpisodeThumbnailCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'episodeThumbnailCache';
  static EpisodeThumbnailCacheManager? _instance;

  factory EpisodeThumbnailCacheManager() {
    _instance ??= EpisodeThumbnailCacheManager._();
    return _instance!;
  }

  EpisodeThumbnailCacheManager._()
      : super(
          Config(
            key,
            // Cache up to 1000 episode thumbnails (TV shows have many episodes)
            maxNrOfCacheObjects: 1000,
            // Keep thumbnails cached for 90 days
            stalePeriod: const Duration(days: 90),
            fileService: HttpFileService(),
          ),
        );
}

/// Custom cache manager for video seek preview sprite sheets.
///
/// Sprite sheets are used during video scrubbing to show frame previews.
///
/// Cache Strategy:
/// - Maximum of 50 cached sprites (only for recently played content)
/// - Images cached for 7 days (can be regenerated, takes more storage)
/// - Uses 'seekSpriteCache' as the cache key
/// - Supports authentication headers for secure access
class SeekSpriteCacheManager extends CacheManager with ImageCacheManager {
  static const key = 'seekSpriteCache';
  static SeekSpriteCacheManager? _instance;

  factory SeekSpriteCacheManager() {
    _instance ??= SeekSpriteCacheManager._();
    return _instance!;
  }

  SeekSpriteCacheManager._()
      : super(
          Config(
            key,
            // Cache up to 50 sprite sheets (only for recently played)
            maxNrOfCacheObjects: 50,
            // Keep sprites cached for 7 days (shorter since they're large)
            stalePeriod: const Duration(days: 7),
            fileService: HttpFileService(),
          ),
        );
}

/// Drops every cache manager singleton so the next use builds a fresh one.
///
/// Each manager's `HttpFileService` creates its `HttpClient` when the manager
/// is first built, so a manager built outside a test's `HttpOverrides` zone
/// keeps a real client for the life of the isolate. `flutter test
/// --concurrency 1` shares one isolate across files, so a test that needs its
/// artwork loads answered by `mockNetworkImages` calls this first, and again
/// when it is done so its mock client does not leak onward.
@visibleForTesting
void resetCacheManagersForTest() {
  PosterCacheManager._instance = null;
  BackdropCacheManager._instance = null;
  EpisodeThumbnailCacheManager._instance = null;
  SeekSpriteCacheManager._instance = null;
}
