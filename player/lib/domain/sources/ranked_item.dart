/// An item with its place in a ranked list, as the Trending rows show it.
library;

import 'package:flutter/foundation.dart';

import 'item.dart';

@immutable
class RankedItem {
  const RankedItem({required this.item, required this.rank});

  final ItemSummary item;

  /// 1 is the top of the list.
  final int rank;

  factory RankedItem.fromJson(Map<String, Object?> json) => RankedItem(
        item: ItemSummary.fromJson(json['item']! as Map<String, Object?>),
        rank: json['rank']! as int,
      );

  Map<String, Object?> toJson() => {'item': item.toJson(), 'rank': rank};

  @override
  bool operator ==(Object other) =>
      other is RankedItem && other.item == item && other.rank == rank;

  @override
  int get hashCode => Object.hash(item, rank);
}
