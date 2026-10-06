/// Cache keys for source data. They are ordinary [QueryKey]s whose operation
/// name is `<sourceId>/<op>`, so the fetch log, the freshness registry, the
/// watcher registry and the invalidator treat them like Mydia's own keys,
/// and a per-source family is a plain [FamilyTarget].
library;

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../cache/invalidation_target.dart';
import '../../cache/query_key.dart';
import '../source.dart';

abstract final class SourceOps {
  static const String libraries = 'libraries';
  static const String browse = 'browse';
  static const String item = 'item';
  static const String children = 'children';
  static const String continueWatching = 'continueWatching';
  static const String hubs = 'hubs';
  static const String similar = 'similar';

  /// Every operation. `source_rules_test.dart` only checks that
  /// `SourceRules.watchedChanged` covers each one; the other rules name
  /// their operations by hand.
  static const Set<String> all = {
    libraries,
    browse,
    item,
    children,
    continueWatching,
    hubs,
    similar,
  };
}

abstract final class SourceKeys {
  static String operation(SourceId id, String op) => '${id.value}/$op';

  static QueryKey libraries(SourceId id) =>
      QueryKey(operation(id, SourceOps.libraries));

  static QueryKey browse(LibraryRef library, BrowseQuery query) => QueryKey(
        operation(library.sourceId, SourceOps.browse),
        {
          'library': library.id,
          'sortId': query.sortId,
          'descending': query.descending,
          'filterIds': query.filterIds.toList()..sort(),
          'pageSize': query.pageSize,
        },
      );

  static QueryKey item(ItemRef ref) => _ofItem(SourceOps.item, ref);

  static QueryKey children(ItemRef ref) => _ofItem(SourceOps.children, ref);

  static QueryKey similar(ItemRef ref) => _ofItem(SourceOps.similar, ref);

  static QueryKey continueWatching(SourceId id) =>
      QueryKey(operation(id, SourceOps.continueWatching));

  static QueryKey hubs(SourceId id) => QueryKey(operation(id, SourceOps.hubs));

  /// Every key of [op] on source [id], whatever its arguments.
  static FamilyTarget family(SourceId id, String op) =>
      FamilyTarget(operation(id, op));

  static QueryKey _ofItem(String op, ItemRef ref) => QueryKey(
        operation(ref.sourceId, op),
        {'kind': ref.kind.name, 'id': ref.externalId},
      );
}
