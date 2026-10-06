import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../sources/source_listing_screen.dart';
import '../sources/source_pages.dart';

class UnwatchedScreen extends ConsumerWidget {
  const UnwatchedScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pages = UnwatchedPages(sourceId);
    final provider = sourcePagesProvider(pages);

    return SourceListingScreen(
      sourceId: sourceId,
      icon: Icons.visibility_off_rounded,
      title: 'Unwatched',
      queryKey: pages.key,
      items: ref.watch(provider).whenData((paged) => paged.items),
      onLoadMore: ref.read(provider.notifier).loadMore,
      onRetry: () => ref.invalidate(provider),
      errorTitle: 'Failed to load unwatched',
      emptyIcon: Icons.check_circle_outline_rounded,
      emptyTitle: 'All caught up!',
      emptySubtitle: "You've watched everything in your library",
    );
  }
}
