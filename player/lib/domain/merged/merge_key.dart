/// One card per title across servers: copies of a title on different
/// servers match on any catalogue id they share.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';
import '../sources/item.dart';

/// The keys [item] matches on: its kind with each catalogue id it has.
/// Empty when it has none, so it matches nothing.
List<String> mergeKeys(ItemSummary item) {
  final ids = item.externalIds;
  final kind = item.ref.kind.name;
  return [
    if (ids.tmdb case final v?) '$kind:tmdb:$v',
    if (ids.tvdb case final v?) '$kind:tvdb:$v',
    if (ids.imdb case final v?) '$kind:imdb:$v',
  ];
}

@immutable
class Deduped {
  const Deduped(this.items, this.extraCopies);

  final List<ItemSummary> items;

  /// For each kept item that stands in for copies, how many it hides.
  final Map<ItemRef, int> extraCopies;
}

/// One item per group of matching copies, at the group's first position.
/// The kept copy is the one furthest into playback, else the one whose
/// server comes first in [order].
Deduped dedupe(List<ItemSummary> items, List<SourceId> order) {
  // Union-find with the smaller index as root, so a root is its group's
  // first position.
  final parent = List<int>.generate(items.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  final owner = <String, int>{};
  for (var i = 0; i < items.length; i++) {
    for (final key in mergeKeys(items[i])) {
      final o = owner[key];
      if (o == null) {
        owner[key] = i;
        continue;
      }
      final x = find(i), y = find(o);
      if (x != y) parent[x < y ? y : x] = x < y ? x : y;
    }
  }

  final groups = <int, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(i);
  }

  int rank(SourceId id) {
    final r = order.indexOf(id);
    return r == -1 ? order.length : r;
  }

  bool better(ItemSummary x, ItemSummary y) {
    final px = x.userState.progressSeconds ?? -1;
    final py = y.userState.progressSeconds ?? -1;
    if (px != py) return px > py;
    return rank(x.ref.sourceId) < rank(y.ref.sourceId);
  }

  final kept = <ItemSummary>[];
  final extra = <ItemRef, int>{};
  for (final members in groups.values) {
    var best = items[members.first];
    for (final m in members.skip(1)) {
      if (better(items[m], best)) best = items[m];
    }
    kept.add(best);
    if (members.length > 1) extra[best.ref] = members.length - 1;
  }
  return Deduped(kept, extra);
}
