/// One merged, sorted grid over several libraries, paged as it scrolls.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../sources/item.dart';
import '../sources/library.dart';
import 'shared_sort_keys.dart';

class GridStream {
  GridStream(
      {required this.source, required this.library, required this.query});

  final MediaSource source;
  final LibraryRef library;
  final BrowseQuery query;
  final List<ItemSummary> buffer = [];
  Cursor? cursor;
  bool exhausted = false;
}

class MergedGrid {
  MergedGrid(
    this._streams, {
    required this.sort,
    required this.descending,
    required this.timeout,
    List<SourceId> unavailable = const [],
    this.skipped = const [],
  }) : unavailable = [...unavailable];

  final List<GridStream> _streams;
  final SharedSort sort;
  final bool descending;
  final Duration timeout;
  final List<SourceId> unavailable;
  final List<SourceId> skipped;
  final List<ItemSummary> items = [];

  bool get hasMore => _streams.any((s) => s.buffer.isNotEmpty || !s.exhausted);

  /// Emits up to [count] more items. An item is emitted only once every
  /// stream still running has one buffered, so the order is exact for the
  /// keys the servers send.
  Future<void> loadMore({int count = 60}) async {
    for (var emitted = 0; emitted < count; emitted++) {
      await Future.wait([
        for (final s in _streams)
          if (s.buffer.isEmpty && !s.exhausted) _fill(s),
      ]);
      GridStream? best;
      for (final s in _streams) {
        if (s.buffer.isEmpty) continue;
        if (best == null ||
            compareForSort(s.buffer.first, best.buffer.first, sort,
                    descending: descending) <
                0) {
          best = s;
        }
      }
      if (best == null) return;
      items.add(best.buffer.removeAt(0));
    }
  }

  Future<void> _fill(GridStream s) async {
    try {
      final page = await s.source
          .browse(s.library, s.query, cursor: s.cursor)
          .timeout(timeout);
      s.buffer.addAll(page.items);
      s.cursor = page.nextCursor;
      if (page.nextCursor == null) s.exhausted = true;
    } catch (e) {
      // A server that fails mid-scroll stops contributing; what it already
      // gave stays where it is.
      debugPrint('All servers: ${s.source.id.value} browse failed: $e');
      s.exhausted = true;
      if (!unavailable.contains(s.source.id)) unavailable.add(s.source.id);
    }
  }
}
