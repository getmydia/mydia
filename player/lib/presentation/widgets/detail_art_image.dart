/// One picture on a detail screen, from whichever server owns it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/artwork_decode.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../domain/detail/detail_art.dart';
import 'artwork_image.dart';

/// Where the picture sits, which picks its cache and decode width.
enum ArtSlot { backdrop, poster, still, person }

class DetailArtImage extends ConsumerWidget {
  const DetailArtImage({
    super.key,
    required this.art,
    required this.slot,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.fallback,
    this.errorWidget,
  });

  final DetailArt? art;
  final ArtSlot slot;
  final BoxFit fit;

  /// Shown while the picture loads. Defaults to nothing.
  final WidgetBuilder? placeholder;

  /// Shown when there is no art at all. Defaults to [placeholder].
  final WidgetBuilder? fallback;

  /// Shown when the picture fails to load. Defaults to [fallback].
  final WidgetBuilder? errorWidget;

  BaseCacheManager? get _cache => switch (slot) {
        ArtSlot.backdrop => BackdropCacheManager(),
        ArtSlot.still => EpisodeThumbnailCacheManager(),
        ArtSlot.poster => PosterCacheManager(),
        ArtSlot.person => null,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = placeholder ?? (_) => const SizedBox.shrink();
    final missing = fallback ?? loading;
    final decodeWidth = slot == ArtSlot.backdrop || slot == ArtSlot.still
        ? viewportDecodeWidth(context, sourceWidth: backdropSourceWidth)
        : null;
    return switch (art) {
      null => missing(context),
      UrlArt(:final url) => ArtworkImage(
          imageUrl: url,
          fit: fit,
          cacheManager: _cache,
          decodeWidth: decodeWidth,
          placeholder: loading,
          errorWidget: errorWidget ?? missing,
        ),
    };
  }
}
