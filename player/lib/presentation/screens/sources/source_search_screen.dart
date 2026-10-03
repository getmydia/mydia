library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/source_artwork.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';

class SourceSearchNotifier extends Notifier<AsyncValue<List<ItemSummary>>?> {
  SourceSearchNotifier(this.sourceId);

  final SourceId sourceId;
  static const _debounce = Duration(milliseconds: 400);
  Timer? _timer;
  int _request = 0;
  String _lastQuery = '';

  @override
  AsyncValue<List<ItemSummary>>? build() {
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
    final searchable =
        ref.read(mediaSourceProvider(sourceId))?.as<Searchable>();
    if (searchable == null) return;
    final request = ++_request;
    state = const AsyncLoading();
    try {
      final results = await searchable.search(text);
      if (ref.mounted && request == _request) state = AsyncData(results);
    } catch (e, st) {
      if (ref.mounted && request == _request) state = AsyncError(e, st);
    }
  }
}

final sourceSearchProvider = NotifierProvider.autoDispose
    .family<SourceSearchNotifier, AsyncValue<List<ItemSummary>>?, SourceId>(
        SourceSearchNotifier.new);

class SourceSearchScreen extends ConsumerWidget {
  const SourceSearchScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(sourceSearchProvider(sourceId));
    final searchable =
        ref.watch(mediaSourceProvider(sourceId))?.as<Searchable>() != null;
    if (!searchable) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text(
            'This server does not support search.',
            key: Key('source-search-unsupported'),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('source-search-field'),
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search this server'),
          onChanged: ref.read(sourceSearchProvider(sourceId).notifier).query,
        ),
      ),
      body: switch (results) {
        null => const SizedBox.shrink(),
        AsyncData(:final value) when value.isEmpty =>
          const Center(child: Text('Nothing found.')),
        AsyncData(:final value) => BrowseGrid(
            scrollTopPadding: 8,
            itemCount: value.length,
            itemBuilder: (context, index) => SourcePoster(
              key: ValueKey('source-poster-${value[index].ref.externalId}'),
              item: value[index],
              onTap: () => context.push(sourceItemLocation(value[index].ref)),
            ),
          ),
        AsyncError(:final error) => SourceErrorView(
            error: error,
            onRetry: ref.read(sourceSearchProvider(sourceId).notifier).retry,
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
