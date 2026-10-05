import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../../widgets/artwork_image.dart';

/// A download's picture: the copy saved beside the file, or for a download
/// made before pictures were saved, the URL it was made from.
///
/// A server path (Plex, Jellyfin, Stash art) is never fetched here: it needs
/// the source's credentials, and the saved copy is the point.
class DownloadArtwork extends StatelessWidget {
  const DownloadArtwork({
    super.key,
    required this.localPath,
    required this.fallbackUrl,
    required this.cacheManager,
    this.fit = BoxFit.cover,
    this.placeholder,
  });

  final String? localPath;
  final String? fallbackUrl;
  final BaseCacheManager cacheManager;
  final BoxFit fit;
  final WidgetBuilder? placeholder;

  @override
  Widget build(BuildContext context) {
    final empty = placeholder?.call(context) ?? const SizedBox.shrink();
    final path = localPath;
    if (path != null && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: fit,
        errorBuilder: (_, __, ___) => empty,
      );
    }
    final url = fallbackUrl;
    if (url != null &&
        (url.startsWith('http://') || url.startsWith('https://'))) {
      return ArtworkImage(
        imageUrl: url,
        cacheManager: cacheManager,
        fit: fit,
        placeholder: placeholder,
        errorWidget: placeholder,
      );
    }
    return empty;
  }
}
