/// What the All servers screens read. [LiveMergedReader] asks every
/// included server live; a local index can replace it later.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/capabilities.dart';
import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../sources/item.dart';
import '../sources/library.dart';
import 'merged_grid.dart';
import 'merged_result.dart';
import 'merged_search.dart';
import 'shared_sort_keys.dart';

abstract interface class MergedLibraryReader {
  Future<MergedResult<List<ItemSummary>>> continueWatching();
  Future<MergedResult<List<ItemSummary>>> recentlyAdded();
  Future<MergedGrid> grid(LibraryKind kind, SharedSort sort,
      {bool? descending});
  Future<MergedResult<MergedSearch>> search(String query);
}

class LiveMergedReader implements MergedLibraryReader {
  LiveMergedReader(
    this.sources, {
    this.timeout = const Duration(seconds: 8),
    this.pageSize = 40,
  });

  /// In display order: ties in rows and search follow it.
  final List<MediaSource> sources;
  final Duration timeout;
  final int pageSize;

  Future<T?> _guard<T>(MediaSource s, Future<T> Function() call) async {
    try {
      return await call().timeout(timeout);
    } catch (e) {
      debugPrint('All servers: ${s.id.value} failed: $e');
      return null;
    }
  }

  Future<MergedResult<List<List<ItemSummary>>>> _each<C extends Object>(
      Future<List<ItemSummary>> Function(C capability) call) async {
    final caps = [for (final s in sources) s.as<C>()];
    final answers = await Future.wait([
      for (var i = 0; i < sources.length; i++)
        if (caps[i] case final c?)
          _guard(sources[i], () => call(c))
        else
          Future<List<ItemSummary>?>.value(),
    ]);
    return MergedResult(
      [for (final a in answers) a ?? const []],
      skipped: [
        for (var i = 0; i < sources.length; i++)
          if (caps[i] == null) sources[i].id
      ],
      unavailable: [
        for (var i = 0; i < sources.length; i++)
          if (caps[i] != null && answers[i] == null) sources[i].id,
      ],
    );
  }

  MergedResult<List<ItemSummary>> _row(MergedResult<List<List<ItemSummary>>> r,
          DateTime? Function(ItemSummary) at) =>
      MergedResult(newestFirst(r.value, at),
          unavailable: r.unavailable, skipped: r.skipped);

  @override
  Future<MergedResult<List<ItemSummary>>> continueWatching() async => _row(
      await _each<ContinueWatching>((c) => c.continueWatching()),
      (i) => i.lastPlayedAt);

  @override
  Future<MergedResult<List<ItemSummary>>> recentlyAdded() async => _row(
      await _each<RecentlyAdded>((c) => c.recentlyAdded()), (i) => i.addedAt);

  @override
  Future<MergedGrid> grid(LibraryKind kind, SharedSort sort,
      {bool? descending}) async {
    final desc = descending ?? defaultDescending(sort);
    final listed =
        await Future.wait([for (final s in sources) _guard(s, s.libraries)]);
    final streams = <GridStream>[];
    final unavailable = <SourceId>[];
    final skipped = <SourceId>[];
    for (var i = 0; i < sources.length; i++) {
      final s = sources[i];
      final libraries = listed[i];
      if (libraries == null) {
        unavailable.add(s.id);
        continue;
      }
      final ofKind = libraries.where((l) => l.kind == kind).toList();
      if (ofKind.isEmpty) continue;
      var joined = false;
      for (final l in ofKind) {
        final option = l.sortOptions.where((o) => o.shared == sort).firstOrNull;
        if (option == null) continue;
        joined = true;
        streams.add(GridStream(
          source: s,
          library: l.ref,
          query: BrowseQuery(
              sortId: option.id, descending: desc, pageSize: pageSize),
        ));
      }
      if (!joined) skipped.add(s.id);
    }
    return MergedGrid(streams,
        sort: sort,
        descending: desc,
        timeout: timeout,
        unavailable: unavailable,
        skipped: skipped);
  }

  @override
  Future<MergedResult<MergedSearch>> search(String query) async {
    final r = await _each<Searchable>((c) => c.search(query));
    return MergedResult(
      MergedSearch({
        for (final section in MergedSection.values)
          if (roundRobin([
            for (final list in r.value)
              [
                for (final i in list)
                  if (sectionOf(i.ref.kind) == section) i
              ],
          ])
              case final items when items.isNotEmpty)
            section: items,
      }),
      unavailable: r.unavailable,
      skipped: r.skipped,
    );
  }
}
