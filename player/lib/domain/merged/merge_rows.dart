/// How a merged row combines every server's answer into one card per title,
/// in an order that never shuffles between loads. Home and the All servers
/// listings both merge through these.
library;

import '../../core/sources/source.dart';
import '../sources/item.dart';
import 'merge_key.dart';
import 'shared_sort_keys.dart';

/// Every server's row as one, newest first by [at], one card per title, at
/// most [limit]. Duplicates collapse before the cap so they do not use up
/// places. [order] names the servers of [perSource], in the same order.
Deduped mergeNewest(
  List<List<ItemSummary>> perSource,
  List<SourceId> order,
  DateTime? Function(ItemSummary) at, {
  int limit = 20,
}) {
  final all = newestFirst(perSource, at,
      limit: perSource.fold(0, (n, l) => n + l.length));
  final d = dedupe(all, order);
  return Deduped(d.items.take(limit).toList(), d.extraCopies);
}

/// Every server's favorites as one, by sort title, one card per title.
/// List.sort is not stable: ties fall back to server order, then each
/// server's own order, so equal titles never swap between loads.
Deduped mergeAlphabetical(
    List<List<ItemSummary>> perSource, List<SourceId> order) {
  String key(ItemSummary i) => (i.sortTitle ?? i.title).toLowerCase();
  final entries = [
    for (var s = 0; s < perSource.length; s++)
      for (var i = 0; i < perSource[s].length; i++)
        (item: perSource[s][i], s: s, i: i),
  ]..sort((x, y) {
      final c = key(x.item).compareTo(key(y.item));
      if (c != 0) return c;
      final s = x.s.compareTo(y.s);
      return s != 0 ? s : x.i.compareTo(y.i);
    });
  return dedupe([for (final e in entries) e.item], order);
}
