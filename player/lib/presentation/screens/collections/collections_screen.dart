import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cache/invalidation_target.dart';
import '../../../core/cache/watcher_registry.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/collection_card.dart';
import '../sources/source_browse_providers.dart';
import '../sources/source_listing_screen.dart';

class CollectionsScreen extends ConsumerWidget {
  const CollectionsScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = sourceCollectionsProvider(sourceId);
    final collectionsData = ref.watch(provider);
    final key = SourceKeys.collections(sourceId);

    return BrowseScaffold(
      icon: Icons.collections_bookmark_rounded,
      title: 'Collections',
      queryKeys: [key],
      actions: sourceSearchActions(context, sourceId),
      onRefresh: () => ref.read(invalidatorProvider).invalidate([key.target]),
      body: (context, scrollTopPadding) => collectionsData.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            _buildErrorView(context, error, () => ref.invalidate(provider)),
        data: (collections) {
          if (collections.isEmpty) {
            return _buildEmptyState(context);
          }
          return CollectionsGrid(
            collections: collections,
            scrollTopPadding: scrollTopPadding,
          );
        },
      ),
    );
  }

  Widget _buildErrorView(
      BuildContext context, Object error, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Failed to load collections',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.collections_bookmark_outlined,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No collections yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Create collections in Mydia to organize your media',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
