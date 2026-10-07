/// One merged, sorted grid over several libraries, paged as it scrolls.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../sources/item.dart';
import '../sources/library.dart';
import 'merge_key.dart';
import 'shared_sort_keys.dart';

class GridStream {
  GridStream(
      {required this.source, required this.library, required this.query});

  final MediaSource source;
  final LibraryRef library;
  final BrowseQuery query;
  final List<ItemSummary> buffer = [];

  /// Every item this stream has buffered, so a server that repeats a page
  /// cannot show the same title twice.
  final Set<ItemRef> seen = {};
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

  /// Kept items that stand in for copies on other servers, and how many.
  final Map<ItemRef, int> extraCopies = {};

  /// Which emitted item each match key belongs to. Earlier in sort order wins.
  final Map<String, ItemRef> _keptBy = {};

  bool get hasMore => _streams.any((s) => s.buffer.isNotEmpty || !s.exhausted);

  /// Emits up to [count] more items. An item is emitted only once every
  /// stream still running has one buffered, so the order is exact for the
  /// keys the servers send.
  ///
  /// Overlapping calls run one after another, so no stream is ever filled
  /// from the same cursor twice.
  Future<void> loadMore({int count = 60}) {
    final run = _tail.then((_) => _loadMore(count));
    _tail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _tail = Future<void>.value();

  Future<void> _loadMore(int count) async {
    for (var emitted = 0; emitted < count; emitted++) {
      await Future.wait([for (final s in _streams) _ensureHead(s)]);
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
      final next = best.buffer.removeAt(0);
      final keys = mergeKeys(next);
      final kept = keys.map((k) => _keptBy[k]).nonNulls.firstOrNull;
      if (kept != null) {
        extraCopies[kept] = (extraCopies[kept] ?? 0) + 1;
        for (final k in keys) {
          _keptBy.putIfAbsent(k, () => kept);
        }
        // A hidden copy does not count toward [count].
        emitted--;
        continue;
      }
      for (final k in keys) {
        _keptBy[k] = next.ref;
      }
      items.add(next);
    }
  }

  /// Consecutive empty pages a stream may answer before it is given up on.
  /// Guards against a server that keeps pointing at new cursors with nothing
  /// on them, which would otherwise hold every other server's items back.
  /// It is reported unavailable rather than finished, so the banner names it
  /// and Retry tries it again.
  static const maxEmptyPages = 20;

  /// Fetches until [s] has an item buffered or has run out.
  Future<void> _ensureHead(GridStream s) async {
    for (var empty = 0; s.buffer.isEmpty && !s.exhausted; empty++) {
      if (empty == maxEmptyPages) {
        debugPrint('All servers: ${s.source.id.value} sent '
            '$maxEmptyPages empty pages in a row; giving up on it');
        _giveUp(s);
        return;
      }
      await _fill(s);
    }
  }

  void _giveUp(GridStream s) {
    s.exhausted = true;
    if (!unavailable.contains(s.source.id)) unavailable.add(s.source.id);
  }

  Future<void> _fill(GridStream s) async {
    try {
      final page = await s.source
          .browse(s.library, s.query, cursor: s.cursor)
          .timeout(timeout);
      // A page of nothing but repeats counts as empty below.
      for (final i in page.items) {
        if (s.seen.add(i.ref)) s.buffer.add(i);
      }
      final next = page.nextCursor;
      // A page that points back at the cursor it was asked with would be
      // fetched again forever, empty or not; its items count once.
      final stuck = next != null && next.value == s.cursor?.value;
      s.cursor = next;
      if (next == null || stuck) s.exhausted = true;
    } catch (e) {
      // A server that fails mid-scroll stops contributing; what it already
      // gave stays where it is.
      debugPrint('All servers: ${s.source.id.value} browse failed: $e');
      _giveUp(s);
    }
  }
}
