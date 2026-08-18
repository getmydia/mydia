import 'query_key.dart';

/// What one entry in an invalidation rule points at.
///
/// [KeyTarget] is one exact operation-plus-variables key, which is what every
/// rule entry used to be. [FamilyTarget] covers every key of one operation
/// whatever its variables, for the case where the mutating screen cannot know
/// them: marking an episode watched has to refresh `CollectionItems`, but the
/// show detail screen has no idea which collections contain that show.
///
/// Sealed so the switch in `Invalidator` is exhaustive at compile time, and a
/// third case cannot be added without every consumer being made to handle it.
sealed class InvalidationTarget {
  const InvalidationTarget();
}

/// One exact key: one operation with one set of variables.
final class KeyTarget extends InvalidationTarget {
  const KeyTarget(this.key);

  final QueryKey key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is KeyTarget && other.key == key);

  @override
  int get hashCode => Object.hash(KeyTarget, key);

  @override
  String toString() => 'KeyTarget($key)';
}

/// Every key for [operationName], whatever its variables.
final class FamilyTarget extends InvalidationTarget {
  const FamilyTarget(this.operationName);

  final String operationName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FamilyTarget && other.operationName == operationName);

  @override
  int get hashCode => Object.hash(FamilyTarget, operationName);

  @override
  String toString() => 'FamilyTarget($operationName)';
}

extension QueryKeyTarget on QueryKey {
  /// This key as an exact invalidation target.
  KeyTarget get target => KeyTarget(this);
}

/// The operation families the rules refer to.
///
/// Lives here rather than beside `QueryKeys` so the dependency stays one-way:
/// this library already imports `query_key.dart` for [KeyTarget], and putting
/// the catalog in `query_key.dart` would point an import back the other way.
abstract final class Families {
  static const FamilyTarget collectionItems = FamilyTarget('CollectionItems');
}
