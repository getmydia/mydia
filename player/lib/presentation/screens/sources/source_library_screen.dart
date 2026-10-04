library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/library.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/source_artwork.dart';
import 'source_browse_providers.dart';
import 'source_drawer_button.dart';
import 'source_error_view.dart';

class SourceLibraryScreen extends ConsumerWidget {
  const SourceLibraryScreen({super.key, required this.library});

  final LibraryRef library;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraries = ref.watch(sourceLibrariesProvider(library.sourceId));
    final info = switch (libraries) {
      AsyncData(:final value) =>
        value.where((l) => l.ref == library).firstOrNull,
      _ => null,
    };
    final browse = ref.watch(libraryBrowseProvider(library));
    final notifier = ref.read(libraryBrowseProvider(library).notifier);
    final query = switch (browse) {
      AsyncData(:final value) => value.query,
      _ => const BrowseQuery(),
    };

    return Scaffold(
      appBar: AppBar(
        leading: SourceDrawerButton.maybe(context),
        title: Text(info?.title ?? ''),
      ),
      body: Column(
        children: [
          if (info != null)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final option in info.sortOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('source-sort-${option.id}'),
                        label: Text(option.label),
                        selected: (query.sortId ?? info.sortOptions.first.id) ==
                            option.id,
                        onSelected: (_) => notifier.setQuery(BrowseQuery(
                            sortId: option.id, filterIds: query.filterIds)),
                      ),
                    ),
                  for (final filter in info.filterOptions)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        key: Key('source-filter-${filter.id}'),
                        label: Text(filter.label),
                        selected: query.filterIds.contains(filter.id),
                        onSelected: (on) => notifier.setQuery(query.copyWith(
                          filterIds: on
                              ? {...query.filterIds, filter.id}
                              : ({...query.filterIds}..remove(filter.id)),
                        )),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: switch (browse) {
              AsyncData(:final value) =>
                NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.metrics.extentAfter < 800) notifier.loadMore();
                    return false;
                  },
                  child: BrowseGrid(
                    scrollTopPadding: 8,
                    itemCount: value.items.length,
                    itemBuilder: (context, index) {
                      final item = value.items[index];
                      return SourcePoster(
                        key: ValueKey('source-poster-${item.ref.externalId}'),
                        item: item,
                        onTap: () => context.push(sourceItemLocation(item.ref)),
                      );
                    },
                  ),
                ),
              AsyncError(:final error) => SourceErrorView(
                  error: error,
                  account: ref
                      .watch(mediaSourceProvider(library.sourceId))
                      ?.source
                      .account,
                  onRetry: () => ref.invalidate(libraryBrowseProvider(library)),
                ),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}
