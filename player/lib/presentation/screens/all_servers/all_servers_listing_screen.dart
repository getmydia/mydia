/// The merged Continue Watching, Recently Added and Favorites lists across
/// every included server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/merged/merged_result.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../widgets/browse_grid.dart';
import '../sources/source_drawer_button.dart';
import '../sources/source_error_view.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

enum AllServersListing { continueWatching, recentlyAdded, favorites }

class AllServersListingScreen extends ConsumerStatefulWidget {
  const AllServersListingScreen({super.key, required this.listing, this.kind});

  final AllServersListing listing;

  /// The starting filter, null for everything.
  final LibraryKind? kind;

  @override
  ConsumerState<AllServersListingScreen> createState() =>
      _AllServersListingScreenState();
}

class _AllServersListingScreenState
    extends ConsumerState<AllServersListingScreen> {
  late LibraryKind? _kind = widget.kind;

  FutureProvider<MergedResult<List<ItemSummary>>> get _provider =>
      switch (widget.listing) {
        AllServersListing.continueWatching =>
          allServersContinueWatchingProvider,
        AllServersListing.recentlyAdded => allServersRecentlyAddedProvider,
        AllServersListing.favorites => allServersFavoritesProvider,
      };

  String get _title => switch (widget.listing) {
        AllServersListing.continueWatching => 'Continue Watching',
        AllServersListing.recentlyAdded => 'Recently Added',
        AllServersListing.favorites => 'Favorites',
      };

  bool _keeps(ItemSummary i) => switch (_kind) {
        null => true,
        LibraryKind.movies => isMovieRow(i),
        _ => !isMovieRow(i),
      };

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    final result = ref.watch(provider);
    final names = ref.watch(allServersNamesProvider);
    final merged = result.value;
    final items = [
      for (final i in stillIncluded(names, merged?.value ?? const []))
        if (_keeps(i)) i
    ];
    void retry() => ref.invalidate(provider);

    return Scaffold(
      appBar: AppBar(
        leading: SourceDrawerButton.maybe(context),
        title: Text(_title),
      ),
      body: Column(
        children: [
          if (widget.listing == AllServersListing.recentlyAdded)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final (key, label, kind) in [
                    ('all', 'All', null),
                    ('movies', 'Movies', LibraryKind.movies),
                    ('shows', 'TV Shows', LibraryKind.shows),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('all-listing-kind-$key'),
                        label: Text(label),
                        selected: _kind == kind,
                        onSelected: (_) => setState(() => _kind = kind),
                      ),
                    ),
                ],
              ),
            ),
          if (merged != null)
            AllServersBanner(unavailable: merged.unavailable, onRetry: retry),
          Expanded(
            child: switch (result) {
              AsyncError(:final error) when merged == null =>
                SourceErrorView(error: error, onRetry: retry),
              _ when merged == null =>
                const Center(child: CircularProgressIndicator()),
              _ => RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(provider);
                    await ref.read(provider.future);
                  },
                  child: BrowseGrid(
                    key: const Key('all-listing-grid'),
                    scrollTopPadding: 8,
                    itemCount: items.length,
                    itemBuilder: (context, index) => AllServersPoster(
                      item: items[index],
                      extraCopies: merged.extraCopies[items[index].ref] ?? 0,
                    ),
                  ),
                ),
            },
          ),
        ],
      ),
    );
  }
}
