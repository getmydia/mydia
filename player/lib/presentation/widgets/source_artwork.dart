/// Posters and backdrops for third-party items: the source turns an
/// `ArtworkRef` into a URL, headers and a cache key.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/poster_cache_manager.dart';
import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../../core/sources/sources_providers.dart';
import '../../domain/models/watch_status.dart';
import '../../domain/sources/item.dart';
import 'artwork_image.dart';
import 'focus_highlight.dart';
import 'media_poster.dart';

final sourceArtworkProvider = FutureProvider.autoDispose
    .family<ArtworkRequest?, ({SourceId sourceId, ArtworkRef art, int width})>(
        (ref, key) async {
  final source = ref.watch(mediaSourceProvider(key.sourceId));
  if (source == null) return null;
  return source.artwork(key.art, width: key.width);
});

/// Null when there is nothing to show: unwatched with no progress.
WatchStatus? watchStatusFor(UserState state, int? durationSeconds) {
  if (state.watched) return const WatchStatus(watched: true);
  final progress = state.progressSeconds ?? 0;
  if (progress <= 0 || durationSeconds == null || durationSeconds <= 0) {
    return null;
  }
  return WatchStatus(
    watched: false,
    percentage: (progress / durationSeconds * 100).clamp(0, 100).toDouble(),
  );
}

ArtworkRequest? _resolved(
  WidgetRef ref,
  SourceId sourceId,
  ArtworkRef? art,
  int width,
) {
  if (art == null) return null;
  return switch (ref.watch(
      sourceArtworkProvider((sourceId: sourceId, art: art, width: width)))) {
    AsyncData(:final value) => value,
    _ => null,
  };
}

class SourcePoster extends ConsumerWidget {
  const SourcePoster({
    super.key,
    required this.item,
    this.onTap,
    this.subtitle,
    this.onContextMenu,
  });

  /// One width for every poster, so one cache entry serves the grid, the
  /// rails and search.
  static const artworkWidth = 400;

  final ItemSummary item;
  final VoidCallback? onTap;

  /// Replaces the item's own caption (its subtitle, else its year).
  final String? subtitle;

  /// Long-press on touch, secondary tap on desktop.
  final void Function(BuildContext posterContext)? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request =
        _resolved(ref, item.ref.sourceId, item.poster, artworkWidth);
    // MediaPoster is a GestureDetector, which a D-pad cannot reach.
    // FocusHighlight makes each poster a focus stop with the app's ring,
    // and OK on a remote activates it like a tap.
    return FocusHighlight(
      onActivate: onTap,
      child: MediaPoster(
        posterUrl: request?.url,
        posterHeaders: request?.headers,
        posterCacheKey: request?.cacheKey,
        title: item.title,
        subtitle: subtitle ?? item.subtitle ?? item.year?.toString(),
        watchStatus: watchStatusFor(item.userState, item.durationSeconds),
        onTap: onTap,
        onContextMenu: onContextMenu,
      ),
    );
  }
}

class SourceBackdrop extends ConsumerWidget {
  const SourceBackdrop({
    super.key,
    required this.sourceId,
    required this.art,
    this.height,
  });

  static const artworkWidth = 1280;

  final SourceId sourceId;
  final ArtworkRef? art;
  final double? height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = _resolved(ref, sourceId, art, artworkWidth);
    if (request == null) {
      return SizedBox(height: height, width: double.infinity);
    }
    return ArtworkImage(
      imageUrl: request.url,
      headers: request.headers,
      cacheKey: request.cacheKey,
      cacheManager: BackdropCacheManager(),
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
    );
  }
}
