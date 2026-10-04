import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart'
    show ImageRenderMethodForWeb;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'replay_safe_codec.dart';

/// Widths the server requests from TMDB, mirrored from
/// `lib/mydia/metadata/image_url.ex` (`poster_url/2` and `backdrop_url/2`).
///
/// Decoding wider than the file is pure waste, so these cap every decode.
/// TVDB artwork arrives as full URLs of other sizes; capping those too keeps
/// their memory bounded at the cost of a slightly softer image.
const int posterSourceWidth = 500;
const int backdropSourceWidth = 1280;

/// How artwork loads on web. The one place this is chosen.
///
/// `cached_network_image` defaults to `HtmlImage`, which hands the URL to
/// `createImageCodecFromUrl`, ignores any decode size and never calls the
/// decode callback. `HttpGet` fetches bytes and decodes them through that
/// callback, which is what lets both the `ResizeImage` target and
/// [ArtworkNetworkImageProvider]'s replay-safe codec apply. TMDB's CDN sends
/// `access-control-allow-origin: *`, which this mode needs. Native platforms
/// ignore the setting.
const ImageRenderMethodForWeb artworkWebRenderMethod =
    ImageRenderMethodForWeb.HttpGet;

/// Bucket size for decode widths.
///
/// Rounding up to a bucket means a window being dragged wider reuses one
/// image-cache entry for a range of widths instead of minting a new decode
/// every frame.
const int _bucket = 64;

/// Physical pixels to decode artwork shown [logicalWidth] wide, or null when
/// the width cannot be sized (unbounded, zero, NaN), which means "no resize".
int? artworkDecodeWidth(
  double logicalWidth,
  double devicePixelRatio, {
  int? sourceWidth,
}) {
  final physical = logicalWidth * devicePixelRatio;
  if (!physical.isFinite || physical <= 0) return null;

  final bucketed = (physical / _bucket).ceil() * _bucket;
  if (sourceWidth != null && bucketed > sourceWidth) return sourceWidth;
  return bucketed;
}

/// [artworkDecodeWidth] for artwork that spans the viewport.
///
/// Used by full-bleed backdrops, and by `AmbientBackdrop`'s precache, which
/// runs outside layout and so cannot use a `LayoutBuilder`. Both sides reading
/// the same MediaQuery values is what keeps their cache keys equal.
int? viewportDecodeWidth(BuildContext context, {int? sourceWidth}) =>
    artworkDecodeWidth(
      MediaQuery.sizeOf(context).width,
      MediaQuery.devicePixelRatioOf(context),
      sourceWidth: sourceWidth,
    );

/// A [CachedNetworkImageProvider] whose codec can be asked for its frame more
/// than once. See [ReplaySafeCodec] for why Firefox and Safari need that.
///
/// The wrap goes around whatever `decode` it is given. Under a [ResizeImage]
/// that is the resizing decoder, which is the codec that must not be
/// re-entered.
class ArtworkNetworkImageProvider extends CachedNetworkImageProvider {
  const ArtworkNetworkImageProvider(
    super.url, {
    super.cacheManager,
    super.headers,
    super.cacheKey,
    this.replaySafe = kIsWeb,
  }) : super(imageRenderMethodForWeb: artworkWebRenderMethod);

  /// Applied on every web browser, not only the ones that need it today, so
  /// there is no browser check to go stale.
  final bool replaySafe;

  @override
  ImageStreamCompleter loadImage(
    CachedNetworkImageProvider key,
    ImageDecoderCallback decode,
  ) =>
      super.loadImage(key, replaySafe ? replaySafeDecode(decode) : decode);
}

/// The provider every network artwork widget resolves. `ArtworkImage` builds
/// it, and so do call sites that need the provider itself (precaching).
///
/// A precache must build its provider through here with the same arguments
/// as the widget, or it warms an entry the widget never reads and the
/// artwork decodes twice.
ImageProvider<Object> artworkImageProvider(
  String url, {
  BaseCacheManager? cacheManager,
  int? decodeWidth,
  Map<String, String>? headers,
  String? cacheKey,
}) =>
    ResizeImage.resizeIfNeeded(
      decodeWidth,
      null,
      ArtworkNetworkImageProvider(
        url,
        cacheManager: cacheManager,
        headers: headers,
        cacheKey: cacheKey,
      ),
    );
