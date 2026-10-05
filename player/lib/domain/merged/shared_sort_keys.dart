/// Ordering for items from several servers.
library;

import '../sources/item.dart';
import '../sources/library.dart';

bool defaultDescending(SharedSort sort) => sort != SharedSort.title;

Comparable<Object>? _key(ItemSummary item, SharedSort sort) => switch (sort) {
      SharedSort.title => (item.sortTitle ?? item.title).toLowerCase(),
      SharedSort.added => item.addedAt,
      // `2021-05-01` and `2021` compare correctly as strings.
      SharedSort.released => item.airDate ?? item.year?.toString(),
    };

/// A total order: the key in [descending] order, missing keys last either
/// way, then source id and external id so pages never reshuffle.
int compareForSort(ItemSummary a, ItemSummary b, SharedSort sort,
    {required bool descending}) {
  final ka = _key(a, sort), kb = _key(b, sort);
  if (ka != null && kb != null) {
    final c = ka.compareTo(kb);
    if (c != 0) return descending ? -c : c;
  } else if (ka != null || kb != null) {
    return ka == null ? 1 : -1;
  }
  final s = a.ref.sourceId.value.compareTo(b.ref.sourceId.value);
  return s != 0 ? s : a.ref.externalId.compareTo(b.ref.externalId);
}

/// Every server's row as one, newest first by [at], at most [limit].
/// Undated items follow, in server order then each server's own order.
List<ItemSummary> newestFirst(
  List<List<ItemSummary>> perSource,
  DateTime? Function(ItemSummary) at, {
  int limit = 20,
}) {
  final entries = [
    for (var s = 0; s < perSource.length; s++)
      for (var i = 0; i < perSource[s].length; i++)
        (item: perSource[s][i], s: s, i: i),
  ];
  entries.sort((x, y) {
    final tx = at(x.item), ty = at(y.item);
    if (tx != null && ty != null) {
      final c = ty.compareTo(tx);
      if (c != 0) return c;
    } else if (tx != null || ty != null) {
      return tx == null ? 1 : -1;
    }
    final s = x.s.compareTo(y.s);
    return s != 0 ? s : x.i.compareTo(y.i);
  });
  return [for (final e in entries.take(limit)) e.item];
}
