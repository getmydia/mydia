import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:octo_image/octo_image.dart';

import '../../core/cache/artwork_decode.dart';

/// The one widget that loads network artwork: posters, backdrops, episode
/// stills, cast photos and seek sprites.
///
/// Everything goes through [artworkImageProvider], which is what keeps
/// artwork from turning black on Firefox and vanishing on Safari after it
/// scrolls back into view. A `CachedNetworkImage` used directly builds its
/// own provider and bypasses that, so
/// `test/presentation/no_raw_cached_network_image_test.dart` forbids it.
///
/// Fades and the empty default placeholder match `CachedNetworkImage`, which
/// this replaces.
class ArtworkImage extends StatelessWidget {
  const ArtworkImage({
    super.key,
    required this.imageUrl,
    this.cacheManager,
    this.decodeWidth,
    this.headers,
    this.cacheKey,
    this.fit,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.fadeInDuration = const Duration(milliseconds: 500),
    this.fadeOutDuration = const Duration(milliseconds: 1000),
  });

  final String imageUrl;

  /// Defaults to `cached_network_image`'s shared cache manager.
  final BaseCacheManager? cacheManager;

  /// Physical pixels to decode at. See `artworkDecodeWidth`. Null decodes at
  /// the source size.
  final int? decodeWidth;

  final Map<String, String>? headers;

  /// Disk-cache identity when the URL is not stable, such as a URL built
  /// against whichever server connection is current.
  final String? cacheKey;
  final BoxFit? fit;
  final Alignment alignment;
  final double? width;
  final double? height;

  /// Shown while the artwork loads.
  final WidgetBuilder? placeholder;

  /// Shown when the artwork fails to load.
  final WidgetBuilder? errorWidget;

  final Duration fadeInDuration;
  final Duration fadeOutDuration;

  @override
  Widget build(BuildContext context) {
    final error = errorWidget;
    return OctoImage(
      image: artworkImageProvider(
        imageUrl,
        cacheManager: cacheManager,
        decodeWidth: decodeWidth,
        headers: headers,
        cacheKey: cacheKey,
      ),
      // OctoImage does not fade without a placeholder, so there is always one.
      placeholderBuilder: placeholder ?? (_) => Container(),
      errorBuilder: error == null ? null : (context, _, __) => error(context),
      fadeInDuration: fadeInDuration,
      fadeOutDuration: fadeOutDuration,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
    );
  }
}
