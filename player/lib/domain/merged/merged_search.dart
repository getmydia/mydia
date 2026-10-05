/// Search results from several servers, sectioned by kind.
library;

import 'package:flutter/foundation.dart';

import '../sources/item.dart';

enum MergedSection { movies, shows, episodes, videos }

MergedSection? sectionOf(ItemKind kind) => switch (kind) {
      ItemKind.movie => MergedSection.movies,
      ItemKind.show => MergedSection.shows,
      ItemKind.episode => MergedSection.episodes,
      ItemKind.video => MergedSection.videos,
      _ => null,
    };

@immutable
class MergedSearch {
  const MergedSearch(this.sections);

  /// Non-empty sections only, in [MergedSection] order.
  final Map<MergedSection, List<ItemSummary>> sections;

  bool get isEmpty => sections.isEmpty;
}

/// First of each list, then second of each, and so on.
List<T> roundRobin<T>(List<List<T>> lists) {
  final out = <T>[];
  for (var i = 0;; i++) {
    var any = false;
    for (final l in lists) {
      if (i < l.length) {
        out.add(l[i]);
        any = true;
      }
    }
    if (!any) return out;
  }
}
