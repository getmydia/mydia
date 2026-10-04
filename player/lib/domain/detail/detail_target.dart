/// Which item a detail screen shows, and which server answers for it.
library;

import 'package:flutter/foundation.dart';

enum DetailKind { movie, show, season, episode }

@immutable
sealed class DetailTarget {
  const DetailTarget();

  DetailKind get kind;

  /// The id the owning server uses.
  String get id;

  /// Keys per-item UI state (selected season, selected episode). A Mydia
  /// target's key is its bare id, which is what those providers were keyed
  /// on before targets existed.
  String get key;
}

final class MydiaTarget extends DetailTarget {
  const MydiaTarget(this.kind, this.id);

  @override
  final DetailKind kind;

  @override
  final String id;

  @override
  String get key => id;

  @override
  bool operator ==(Object other) =>
      other is MydiaTarget && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'MydiaTarget(${kind.name}, $id)';
}
