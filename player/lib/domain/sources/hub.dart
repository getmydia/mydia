/// A row the server itself curates, such as Plex's "Recently Released".
library;

import 'package:flutter/foundation.dart';

import 'item.dart';
import 'library.dart';

@immutable
class Hub {
  const Hub({
    required this.id,
    required this.title,
    required this.items,
    this.library,
  });

  /// The server's identifier for the hub, stable across requests.
  final String id;
  final String title;
  final List<ItemSummary> items;

  /// The library the row's title opens, when every item is from one.
  final LibraryRef? library;
}
