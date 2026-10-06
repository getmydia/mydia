/// What the All servers screens read. [LiveMergedReader] asks every
/// included server live; a local index can replace it later.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/capabilities.dart';
import '../../core/sources/media_source.dart';
import '../../core/sources/source.dart';
import '../sources/item.dart';
import '../sources/library.dart';
import 'merge_key.dart';
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

  List<SourceId> get _order => [for (final s in sources) s.id];

  /// Every server's row, newest first, one card per title, at most [limit].
  /// Duplicates collapse before the cap so they do not use up places.
  MergedResult<List<ItemSummary>> _row(MergedResult<List<List<ItemSummary>>> r,
      DateTime? Function(ItemSummary) at,
      {int limit = 20}) {
    final all = newestFirst(r.value, at,
        limit: r.value.fold(0, (n, l) => n + l.length));
    final d = dedupe(all, _order);
    return MergedResult(d.items.take(limit).toList(),
        unavailable: r.unavailable,
        skipped: r.skipped,
        extraCopies: d.extraCopies);
  }

  @override
  Future<MergedResult<List<ItemSummary>>> continueWatching() async => _row(
      await _each<ContinueWatching>((c) => c.continueWatching()),
      (i) => i.lastPlayedAt);

  @override
  Future<MergedResult<List<ItemSummary>>> recentlyAdded() async => _row(
      await _each<RecentlyAdded>((c) => c.recentlyAdded()), (i) => i.addedAt,
      // The home splits this into movies and TV, so each half needs room.
      limit: 40);

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
    final sections = <MergedSection, List<ItemSummary>>{};
    final extra = <ItemRef, int>{};
    for (final section in MergedSection.values) {
      final d = dedupe(
          roundRobin([
            for (final list in r.value)
              [
                for (final i in list)
                  if (sectionOf(i.ref.kind) == section) i
              ],
          ]),
          _order);
      if (d.items.isEmpty) continue;
      sections[section] = d.items;
      extra.addAll(d.extraCopies);
    }
    return MergedResult(MergedSearch(sections),
        unavailable: r.unavailable, skipped: r.skipped, extraCopies: extra);
  }
}
