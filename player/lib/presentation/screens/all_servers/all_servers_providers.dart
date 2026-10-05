/// The All servers views' state.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/merged/merged_grid.dart';
import '../../../domain/merged/merged_library_reader.dart';
import '../../../domain/merged/merged_result.dart';
import '../../../domain/merged/merged_search.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';

final allServersReaderProvider = Provider.autoDispose<MergedLibraryReader>(
    (ref) => LiveMergedReader(ref.watch(allServersSourcesProvider)));

/// Display name per included source.
final allServersNamesProvider =
    Provider.autoDispose<Map<SourceId, String>>((ref) => {
          for (final s in ref.watch(allServersSourcesProvider))
            s.id: s.displayName,
        });

final allServersContinueWatchingProvider =
    FutureProvider.autoDispose<MergedResult<List<ItemSummary>>>(
        (ref) => ref.watch(allServersReaderProvider).continueWatching());

final allServersRecentlyAddedProvider =
    FutureProvider.autoDispose<MergedResult<List<ItemSummary>>>(
        (ref) => ref.watch(allServersReaderProvider).recentlyAdded());

@immutable
class AllServersGridState {
  const AllServersGridState({
    required this.items,
    required this.sort,
    this.unavailable = const [],
    this.skipped = const [],
    this.hasMore = false,
    this.loadingMore = false,
  });

  final List<ItemSummary> items;
  final SharedSort sort;
  final List<SourceId> unavailable;
  final List<SourceId> skipped;
  final bool hasMore;
  final bool loadingMore;
}

class AllServersGridNotifier extends AsyncNotifier<AllServersGridState> {
  AllServersGridNotifier(this.kind);

  final LibraryKind kind;
  SharedSort _sort = SharedSort.title;
  MergedGrid? _grid;

  AllServersGridState _from(MergedGrid g, {bool loadingMore = false}) =>
      AllServersGridState(
        items: List.unmodifiable(g.items),
        sort: g.sort,
        unavailable: List.unmodifiable(g.unavailable),
        skipped: g.skipped,
        hasMore: g.hasMore,
        loadingMore: loadingMore,
      );

  @override
  Future<AllServersGridState> build() async {
    final grid = await ref.watch(allServersReaderProvider).grid(kind, _sort);
    await grid.loadMore();
    _grid = grid;
    return _from(grid);
  }

  void setSort(SharedSort sort) {
    if (sort == _sort) return;
    _sort = sort;
    ref.invalidateSelf();
  }

  Future<void> loadMore() async {
    final grid = _grid;
    final current = state.value;
    if (grid == null ||
        current == null ||
        current.loadingMore ||
        !grid.hasMore) {
      return;
    }
    state = AsyncData(_from(grid, loadingMore: true));
    try {
      await grid.loadMore();
    } catch (_) {
      // loadingMore must not stick.
    }
    // A sort change while paging replaced the grid; drop this page.
    if (!ref.mounted || !identical(grid, _grid)) return;
    state = AsyncData(_from(grid));
  }
}

final allServersGridProvider = AsyncNotifierProvider.autoDispose
    .family<AllServersGridNotifier, AllServersGridState, LibraryKind>(
        AllServersGridNotifier.new);

class AllServersSearchNotifier
    extends Notifier<AsyncValue<MergedResult<MergedSearch>>?> {
  static const _debounce = Duration(milliseconds: 400);
  Timer? _timer;
  int _request = 0;
  String _lastQuery = '';

  @override
  AsyncValue<MergedResult<MergedSearch>>? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void query(String text) {
    _timer?.cancel();
    // Any newer input outdates a search still in flight.
    _request++;
    final trimmed = text.trim();
    _lastQuery = trimmed;
    if (trimmed.isEmpty) {
      state = null;
      return;
    }
    _timer = Timer(_debounce, () => _run(trimmed));
  }

  /// Runs the last query again, for the error view's retry.
  void retry() {
    final text = _lastQuery;
    if (text.isNotEmpty) _run(text);
  }

  Future<void> _run(String text) async {
    final request = ++_request;
    state = const AsyncLoading();
    try {
      final results = await ref.read(allServersReaderProvider).search(text);
      if (ref.mounted && request == _request) state = AsyncData(results);
    } catch (e, st) {
      if (ref.mounted && request == _request) state = AsyncError(e, st);
    }
  }
}

final allServersSearchProvider = NotifierProvider.autoDispose<
    AllServersSearchNotifier,
    AsyncValue<MergedResult<MergedSearch>>?>(AllServersSearchNotifier.new);
