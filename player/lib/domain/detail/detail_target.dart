/// Which item a detail screen shows, and which server answers for it.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';
import '../sources/item.dart';

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

  final ItemRef ref;

  /// Only built for kinds [detailKindOf] maps.
  @override
  DetailKind get kind => detailKindOf(ref.kind)!;

  @override
  String get id => ref.externalId;

  @override
  String get key => '${ref.sourceId.value}|${ref.kind.name}|${ref.externalId}';

  @override
  bool operator ==(Object other) => other is SourceTarget && other.ref == ref;

  @override
  int get hashCode => ref.hashCode;

  @override
  String toString() => 'SourceTarget($key)';
}

/// The item [target] names. A [MydiaTarget] belongs to [bound], the Mydia
/// instance the legacy screens serve; with none bound it gets [SourceId.none],
/// which no source answers to.
ItemRef itemRefOf(DetailTarget target, SourceId? bound) => switch (target) {
      SourceTarget(:final ref) => ref,
      MydiaTarget(:final kind, :final id) => ItemRef(
          sourceId: bound ?? SourceId.none,
          kind: switch (kind) {
            DetailKind.movie => ItemKind.movie,
            DetailKind.show => ItemKind.show,
            DetailKind.season => ItemKind.season,
            DetailKind.episode => ItemKind.episode,
          },
          externalId: id,
        ),
    };
