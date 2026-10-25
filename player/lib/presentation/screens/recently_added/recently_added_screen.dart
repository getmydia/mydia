import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/source.dart';
import '../../../l10n/l10n.dart';
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
      title: context.l10n.navRecentlyAdded,
      queryKey: SourceKeys.recentlyAdded(sourceId),
      items: ref.watch(provider),
      onRetry: () => ref.invalidate(provider),
      errorTitle: context.l10n.recentlyAddedLoadFailed,
      emptyIcon: Icons.fiber_new_rounded,
      emptyTitle: context.l10n.recentlyAddedEmptyTitle,
      emptySubtitle: context.l10n.recentlyAddedEmptySubtitle,
    );
  }
}
