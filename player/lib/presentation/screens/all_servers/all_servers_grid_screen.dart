/// The merged Movies and TV Shows grid across every included server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/sources/library.dart';
import '../../widgets/browse_grid.dart';
import '../sources/source_drawer_button.dart';
import '../sources/source_error_view.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

String _sortLabel(SharedSort sort) => switch (sort) {
      SharedSort.title => 'Title',
      SharedSort.added => 'Date added',
      SharedSort.released => 'Release date',
    };

class AllServersGridScreen extends ConsumerWidget {
  const AllServersGridScreen({super.key, required this.kind});

  final LibraryKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grid = ref.watch(allServersGridProvider(kind));
    final notifier = ref.read(allServersGridProvider(kind).notifier);
    final names = ref.watch(allServersNamesProvider);
    final state = grid.value;
    void retry() => ref.invalidate(allServersGridProvider(kind));

    return Scaffold(
      appBar: AppBar(
        leading: SourceDrawerButton.maybe(context),
        title: Text(kind == LibraryKind.shows ? 'TV Shows' : 'Movies'),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final s in SharedSort.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: Key('all-grid-sort-${s.name}'),
                      label: Text(_sortLabel(s)),
                      selected: (state?.sort ?? SharedSort.title) == s,
                      onSelected: (_) => notifier.setSort(s),
                    ),
                  ),
              ],
            ),
          ),
          if (state != null && state.skipped.isNotEmpty)
            Padding(
              key: const Key('all-sort-skipped-note'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Not sorted by ${_sortLabel(state.sort)} on '
                '${state.skipped.map((id) => names[id] ?? id.value).join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (state != null)
            AllServersBanner(unavailable: state.unavailable, onRetry: retry),
          Expanded(
            child: switch (grid) {
              AsyncError(:final error) when state == null =>
                SourceErrorView(error: error, onRetry: retry),
              _ when state == null =>
                const Center(child: CircularProgressIndicator()),
              _ => NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 800) notifier.loadMore();
                    return false;
                  },
                  child: BrowseGrid(
                    scrollTopPadding: 8,
                    itemCount: state.items.length,
                    itemBuilder: (context, index) =>
                        AllServersPoster(item: state.items[index]),
                  ),
                ),
            },
          ),
        ],
      ),
    );
  }
}
