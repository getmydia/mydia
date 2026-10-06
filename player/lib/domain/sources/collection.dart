/// A server-side grouping of items, as the Collections screen lists it.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';
import 'item.dart';

@immutable
class SourceCollection {
  const SourceCollection({
    required this.sourceId,
    required this.id,
    required this.name,
    this.description,
    this.smart = false,
    this.itemCount = 0,
    this.posters = const [],
  });

  final SourceId sourceId;
  final String id;
  final String name;
  final String? description;
  final bool smart;
  final int itemCount;

  /// Up to four item posters, for the collection card's mosaic.
  final List<ArtworkRef> posters;

  factory SourceCollection.fromJson(Map<String, Object?> json) =>
      SourceCollection(
        sourceId: SourceId(json['sourceId']! as String),
        id: json['id']! as String,
        name: json['name']! as String,
        description: json['description'] as String?,
        smart: json['smart'] as bool? ?? false,
        itemCount: json['itemCount'] as int? ?? 0,
        posters: [
          for (final p in (json['posters'] as List?) ?? const [])
            ArtworkRef(p as String),
        ],
      );

  Map<String, Object?> toJson() => {
        'sourceId': sourceId.value,
        'id': id,
        'name': name,
        'description': description,
        'smart': smart,
        'itemCount': itemCount,
        'posters': [for (final p in posters) p.path],
      };
}
