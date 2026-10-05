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

  factory Hub.fromJson(Map<String, Object?> json) => Hub(
        id: json['id']! as String,
        title: json['title']! as String,
        items: [
          for (final e in (json['items'] as List?) ?? const [])
            ItemSummary.fromJson(e as Map<String, Object?>),
        ],
        library: json['library'] == null
            ? null
            : LibraryRef.fromJson(json['library']! as Map<String, Object?>),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'items': [for (final i in items) i.toJson()],
        'library': library?.toJson(),
      };
}
