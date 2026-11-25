/// Where a scene was opened from, carried on the route so the player can ask
/// the source for the previous and next scene of that same listing.
library;

import 'package:flutter/foundation.dart';

import 'item.dart';

/// The listing a scene was opened from.
enum SequenceOrigin { library, search, continueWatching }

@immutable
class PlaybackSequence {
  const PlaybackSequence({
    required this.origin,
    required this.position,
    this.sortId,
    this.descending,
    this.filterIds = const {},
    this.query,
  });

  final SequenceOrigin origin;

  /// Zero-based index of the current item in the listing.
  final int position;
  final String? sortId;
  final bool? descending;
  final Set<String> filterIds;
  final String? query;

  PlaybackSequence at(int position) => PlaybackSequence(
    origin: origin,
    position: position,
    sortId: sortId,
    descending: descending,
    filterIds: filterIds,
    query: query,
  );

  Map<String, String> toQuery() => {
    'seq': origin.name,
    'seqPos': '$position',
    'seqSort': ?sortId,
    if (descending != null) 'seqDesc': descending! ? '1' : '0',
    if (filterIds.isNotEmpty)
      'seqFilter': (filterIds.toList()..sort()).join(','),
    'seqQ': ?query,
  };

  static PlaybackSequence? fromQuery(Map<String, String> q) {
    final origin = SequenceOrigin.values.asNameMap()[q['seq']];
    final position = int.tryParse(q['seqPos'] ?? '');
    if (origin == null || position == null || position < 0) return null;
    final desc = q['seqDesc'];
    final filter = q['seqFilter'];
    return PlaybackSequence(
      origin: origin,
      position: position,
      sortId: q['seqSort'],
      descending: desc == null ? null : desc == '1',
      filterIds: filter == null || filter.isEmpty
          ? const {}
          : filter.split(',').toSet(),
      query: q['seqQ'],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlaybackSequence &&
      other.origin == origin &&
      other.position == position &&
      other.sortId == sortId &&
      other.descending == descending &&
      setEquals(other.filterIds, filterIds) &&
      other.query == query;

  @override
  int get hashCode => Object.hash(
    origin,
    position,
    sortId,
    descending,
    Object.hashAllUnordered(filterIds),
    query,
  );

  @override
  String toString() => 'PlaybackSequence(${toQuery()})';
}

@immutable
class SequenceNeighbour {
  const SequenceNeighbour({required this.item, required this.position});
  final ItemSummary item;
  final int position;
}

@immutable
class SequenceNeighbours {
  const SequenceNeighbours({this.previous, this.next});
  static const none = SequenceNeighbours();
  final SequenceNeighbour? previous;
  final SequenceNeighbour? next;
}
