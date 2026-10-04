/// A picture on a detail screen. Mydia hands out plain URLs; other servers
/// need their source to add credentials, which never go in the URL.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';
import '../sources/item.dart';

@immutable
sealed class DetailArt {
  const DetailArt();
}

final class UrlArt extends DetailArt {
  const UrlArt(this.url);

  final String url;

  @override
  bool operator ==(Object other) => other is UrlArt && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// A picture the owning source resolves, adding credentials as headers.
final class SourceArt extends DetailArt {
  const SourceArt(this.sourceId, this.ref);

  final SourceId sourceId;
  final ArtworkRef ref;

  @override
  bool operator ==(Object other) =>
      other is SourceArt && other.sourceId == sourceId && other.ref == ref;

  @override
  int get hashCode => Object.hash(sourceId, ref);
}
