import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/source.dart';
import '../sources/source_browse_providers.dart';
import '../sources/source_listing_screen.dart';

class RecentlyAddedScreen extends ConsumerWidget {
  const RecentlyAddedScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = sourceRecentlyAddedProvider(sourceId);

    return SourceListingScreen(
      sourceId: sourceId,
      icon: Icons.fiber_new_rounded,
      title: 'Recently Added',
      queryKey: SourceKeys.recentlyAdded(sourceId),
      items: ref.watch(provider),
      onRetry: () => ref.invalidate(provider),
      errorTitle: 'Failed to load recently added',
      emptyIcon: Icons.fiber_new_rounded,
      emptyTitle: 'Nothing new',
      emptySubtitle: 'Recently added content will appear here',
    );
  }
}
