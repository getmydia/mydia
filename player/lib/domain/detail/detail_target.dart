/// Which item a detail screen shows, and which server answers for it.
library;

import 'package:flutter/foundation.dart';

import '../sources/item.dart';

enum DetailKind { movie, show, season, episode }

@immutable
sealed class DetailTarget {
  const DetailTarget();

  DetailKind get kind;

  /// The id the owning server uses.
  String get id;

  /// The item this target names, on the source that owns it.
  ItemRef get ref;
}

/// Null for a kind the detail screens do not show (video, folder).
DetailKind? detailKindOf(ItemKind kind) => switch (kind) {
      ItemKind.movie => DetailKind.movie,
      ItemKind.show => DetailKind.show,
      ItemKind.season => DetailKind.season,
      ItemKind.episode => DetailKind.episode,
      ItemKind.video || ItemKind.folder => null,
    };

final class SourceTarget extends DetailTarget {
  const SourceTarget(this.ref);

  @override
  final ItemRef ref;

  /// Only built for kinds [detailKindOf] maps.
  @override
  DetailKind get kind => detailKindOf(ref.kind)!;

  @override
  String get id => ref.externalId;

  @override
  bool operator ==(Object other) => other is SourceTarget && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;

  @override
  String toString() =>
      'SourceTarget(${ref.sourceId.value}|${ref.kind.name}|${ref.externalId})';
}
