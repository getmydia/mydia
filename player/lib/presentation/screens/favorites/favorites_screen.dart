import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../sources/source_listing_screen.dart';
import '../sources/source_pages.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = FavoritePages(sourceId);
    final provider = sourcePagesProvider(pages);

    return SourceListingScreen(
      sourceId: sourceId,
      icon: Icons.favorite_rounded,
      title: 'Favorites',
      queryKey: pages.key,
      items: ref.watch(provider).whenData((paged) => paged.items),
      onLoadMore: ref.read(provider.notifier).loadMore,
      onRetry: () => ref.invalidate(provider),
      errorTitle: 'Failed to load favorites',
      emptyIcon: Icons.favorite_outline_rounded,
      emptyTitle: 'No favorites yet',
      emptySubtitle: 'Mark movies and shows as favorites to see them here',
    );
  }
}
