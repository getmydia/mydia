/// A picture on a detail screen. Mydia hands out plain URLs; other servers
/// need their source to add credentials, which never go in the URL.
library;

import 'package:flutter/foundation.dart';

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
