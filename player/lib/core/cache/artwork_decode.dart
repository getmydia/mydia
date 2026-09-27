import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart'
    show ImageRenderMethodForWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

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
/// `createImageCodecFromUrl` and ignores any decode size, so every poster
/// decoded at full resolution. That is also CanvasKit's lazy `<img>` texture
/// path, where Firefox logs "Uploading zeros" and paints black posters once
/// GPU memory runs short. `HttpGet` fetches bytes and decodes them to the
/// `ResizeImage` target. TMDB's CDN sends `access-control-allow-origin: *`,
/// which this mode needs. Native platforms ignore the setting.
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

/// The provider `CachedNetworkImage(imageUrl: url, cacheManager: ...,
/// memCacheWidth: decodeWidth, imageRenderMethodForWeb: artworkWebRenderMethod)`
/// resolves, for call sites that need the provider itself (precaching).
///
/// It must stay equal to what that widget builds, or a precache warms an
/// entry the widget never reads and the artwork decodes twice. The widget
/// wraps its provider with `ResizeImage.resizeIfNeeded(memCacheWidth, null,
/// ...)` (octo_image), and this does the same.
ImageProvider<Object> artworkImageProvider(
  String url, {
  required BaseCacheManager cacheManager,
  int? decodeWidth,
}) =>
    ResizeImage.resizeIfNeeded(
      decodeWidth,
      null,
      CachedNetworkImageProvider(
        url,
        cacheManager: cacheManager,
        imageRenderMethodForWeb: artworkWebRenderMethod,
      ),
    );
